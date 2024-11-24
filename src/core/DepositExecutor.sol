// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Ownable2Step, Ownable } from "@openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { ILayerZeroComposer } from "src/interfaces/ILayerZeroComposer.sol";
import { IWETH } from "src/interfaces/IWETH.sol";
import { ERC20, SafeTransferLib } from "@royco/src/RecipeMarketHub.sol";
import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { ClonesWithImmutableArgs } from "@clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import { IOFT } from "src/interfaces/IOFT.sol";
import { OFTComposeMsgCodec } from "src/libraries/OFTComposeMsgCodec.sol";
import { CCDMPayloadLib } from "src/libraries/CCDMPayloadLib.sol";

/// @title DepositExecutor
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A singleton contract for receiving and deploying bridged deposits on the destination chain for all deposit campaigns.
/// @notice This contract implements ILayerZeroComposer to execute logic based on the compose messages sent from the source chain.
contract DepositExecutor is ILayerZeroComposer, Ownable2Step, ReentrancyGuardTransient {
    using CCDMPayloadLib for bytes;
    using ClonesWithImmutableArgs for address;
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                Structures
    //////////////////////////////////////////////////////////////*/

    /// @dev Represents a recipe containing Weiroll commands and state.
    /// @custom:field weirollCommands The weiroll script executed on a depositor's Weiroll Wallet.
    /// @custom:field weirollState State of the Weiroll VM, necessary for executing the Weiroll script.
    struct Recipe {
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    /// @dev Represents a Deposit Campaign on the destination chain.
    /// @custom:field owner The address of the owner of this deposit campaign.
    /// @custom:field inputTokens The input tokens that will be deposited by the campaign's deposit recipe.
    /// @custom:field receiptToken The receipt token returned to the Weiroll Wallet upon executing the deposit recipe.
    /// @custom:field unlockTimestamp The ABSOLUTE timestamp until deposits will be locked for this campaign.
    /// @custom:field depositRecipe The Weiroll Recipe executed on deposit (specified by the owner of the campaign).
    /// @custom:field verified A flag indicating whether this campaign's input tokens, receipt token, and deposit recipe are verified.
    /// @custom:field ccdmBridgeNonceToWeirollWallet Mapping from a CCDM bridge nonce to its corresponding Weiroll Wallet.
    /// @custom:field weirollWalletToAccounting Mapping from a Weiroll Wallet to its corresponding depositor accounting data.
    struct DepositCampaign {
        address owner;
        ERC20[] inputTokens;
        ERC20 receiptToken;
        uint256 unlockTimestamp;
        Recipe depositRecipe;
        bool verified;
        mapping(uint256 => address) ccdmBridgeNonceToWeirollWallet;
        mapping(address => WeirollWalletAccounting) weirollWalletToAccounting;
    }

    /// @dev Holds the granular depositor balances of a WeirollWallet.
    /// @custom:field depositorToTokenToAmount Mapping to account for depositor's balance of each token in this Weiroll Wallet.
    /// @custom:field tokenToTotalAmount Mapping to account for total amounts deposited for each token in this Weiroll Wallet.
    struct WeirollWalletAccounting {
        mapping(address => mapping(ERC20 => uint256)) depositorToTokenToAmountDeposited;
        mapping(ERC20 => uint256) tokenToTotalAmountDeposited;
    }

    /*//////////////////////////////////////////////////////////////
                            State Variables
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the Weiroll wallet implementation used for cloning.
    address public immutable WEIROLL_WALLET_IMPLEMENTATION;

    /// @notice The address of the LayerZero V2 Endpoint contract on the destination chain.
    address public immutable LAYER_ZERO_V2_ENDPOINT;

    /// @notice The wrapped native asset token on the destination chain.
    address public immutable WRAPPED_NATIVE_ASSET_TOKEN;

    /// @notice The address of the script verifier responsible for verifying campaign input tokens, receipt tokens, and scripts before execution.
    address public scriptVerifier;

    /// @dev Mapping from a source market hash to its DepositCampaign struct.
    mapping(bytes32 => DepositCampaign) public sourceMarketHashToDepositCampaign;

    /// @dev Mapping from a source market hash to whether or not the first deposit script has been executed.
    mapping(bytes32 => bool) public sourceMarketHashToFirstDepositExecuted;

    /*//////////////////////////////////////////////////////////////
                            Events and Errors
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when lzCompose is executed for a bridge transaction.
     * @param sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param guid The global unique identifier of the LayerZero V2 bridge transaction.
     * @param ccdmBridgeNonce The nonce for the CCDM bridge transaction.
     * @param weirollWallet The weiroll wallet associated with this CCDM bridge nonce for this campaign.
     */
    event CCDMBridgeProcessed(bytes32 indexed sourceMarketHash, bytes32 indexed guid, uint256 indexed ccdmBridgeNonce, address weirollWallet);

    /**
     * @notice Emitted on batch execute of Weiroll Wallet deposits.
     * @param sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param weirollWalletsExecuted The addresses of the weiroll wallets that executed the campaign's deposit recipe.
     */
    event WeirollWalletsExecutedDeposits(bytes32 indexed sourceMarketHash, address[] weirollWalletsExecuted);

    /**
     * @param weirollWallet The Weiroll Wallet that the depositor was withdrawn from.
     * @param depositor The address of the depositor withdrawan from the Weiroll Wallet.
     */
    event DepositorWithdrawn(address indexed weirollWallet, address indexed depositor);

    /**
     * @notice Emitted when the script verifier address is set.
     * @param scriptVerifier The address of the new script verifier.
     */
    event ScriptVerifierSet(address scriptVerifier);

    /**
     * @notice Emitted when a campaign's updates are verified.
     * @param sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param verificationStatus Boolean indicating whether the campaign verification was given or revoked.
     */
    event ScriptVerificationStatusUpdated(bytes32 indexed sourceMarketHash, bool verificationStatus);

    /**
     * @notice Emitted when a new owner is set for a campaign.
     * @param sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param newOwner The address of the new campaign owner.
     */
    event CampaignOwnerSet(bytes32 indexed sourceMarketHash, address newOwner);

    /**
     * @notice Emitted when the unlock timestamp for a Deposit Campaign is set.
     * @param sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param unlockTimestamp The ABSOLUTE timestamp until deposits will be locked for this campaign.
     */
    event CampaignUnlockTimestampSet(bytes32 indexed sourceMarketHash, uint256 unlockTimestamp);

    /**
     * @notice Emitted when the input tokens of a Deposit Campaign are set.
     * @param sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param inputTokens The array of input tokens set for this deposit campaign.
     */
    event CampaignInputTokensSet(bytes32 indexed sourceMarketHash, ERC20[] inputTokens);

    /**
     * @notice Emitted when the receipt token of a Deposit Campaign is set.
     * @param sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param receiptToken The receipt token set for this deposit campaign.
     */
    event CampaignReceiptTokenSet(bytes32 indexed sourceMarketHash, ERC20 receiptToken);

    /**
     * @notice Emitted when the deposit recipe of a Deposit Campaign is set.
     * @param sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     */
    event CampaignDepositRecipeSet(bytes32 indexed sourceMarketHash);

    /// @notice Error emitted when the caller is not the scriptVerifier.
    error OnlyScriptVerifier();

    /// @notice Error emitted when the caller is not the owner of the campaign.
    error OnlyCampaignOwner();

    /// @notice Error emitted when campaign owner trying to execute the script when unverified.
    error CampaignIsUnverified();

    /// @notice Error emitted when the caller is not the owner of the Weiroll wallet.
    error NotOwner();

    /// @notice Error emitted when trying to set a campaign's unlock timestamp more than once.
    error CampaignUnlockTimestampCanOnlyBeSetOnce();

    /// @notice Error emitted when the caller of the lzCompose function isn't the LZ endpoint address for destination chain.
    error NotFromLzV2Endpoint();

    /// @notice Error emitted when executing the deposit recipe doesn't return any receipt tokens to the Weiroll Wallet.
    error MustReturnReceiptTokensOnDeposit();

    /// @notice Error emitted when executing the deposit recipe doesn't render a max allowance for the DepositExecutor on the Weiroll Wallet.
    error MustMaxAllowDepositExecutor();

    /// @notice Error emitted when trying to interact with a locked wallet.
    error WalletLocked();

    /// @notice Error emitted when the caller of the composeMsg instructs the executor to deploy more funds into Weiroll Wallets than were bridged.
    error CantAccountForMoreDepositsThanBridged();

    /*//////////////////////////////////////////////////////////////
                                  Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier to ensure the caller is the global scriptVerifier.
    modifier onlyScriptVerifier() {
        require(msg.sender == scriptVerifier, OnlyScriptVerifier());
        _;
    }

    /// @dev Modifier to ensure the caller is the owner of the campaign.
    modifier onlyCampaignOwner(bytes32 _sourceMarketHash) {
        require(msg.sender == sourceMarketHashToDepositCampaign[_sourceMarketHash].owner, OnlyCampaignOwner());
        _;
    }

    /// @dev Modifier to ensure the caller is the owner of the campaign or the owner of the DepositExecutor.
    modifier onlyCampaignOwnerOrDepositExecutorOwner(bytes32 _sourceMarketHash) {
        require(msg.sender == sourceMarketHashToDepositCampaign[_sourceMarketHash].owner || msg.sender == owner(), OnlyCampaignOwner());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                Constructor
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the DepositExecutor Contract.
     * @param _owner The address of the owner of this contract.
     * @param _lzV2Endpoint The address of the LayerZero V2 Endpoint on the destination chain.
     * @param _scriptVerifier The address of the script verifier.
     * @param _wrapped_native_asset_token The address of the wrapped native asset token on the destination chain.
     */
    constructor(address _owner, address _lzV2Endpoint, address _scriptVerifier, address _wrapped_native_asset_token) Ownable(_owner) {
        // Deploy the Weiroll Wallet implementation on the destination chain to use for cloning with immutable args
        WEIROLL_WALLET_IMPLEMENTATION = address(new WeirollWallet());

        // Initialize the DepositExecutor's state
        LAYER_ZERO_V2_ENDPOINT = _lzV2Endpoint;
        scriptVerifier = _scriptVerifier;
        WRAPPED_NATIVE_ASSET_TOKEN = _wrapped_native_asset_token;
    }

    /*//////////////////////////////////////////////////////////////
                            External Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Composes a LayerZero message from an OApp.
     * @dev This function is called by the LayerZero V2 Endpoint when a message is composed.
     * It processes the message and handles the bridging of deposits.
     * @param _from The address initiating the composition (LayerZero OApp).
     * @param _guid The unique identifier for the corresponding LayerZero src/dst transaction.
     * @param _message The composed message payload in bytes.
     */
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata) external payable nonReentrant {
        // Ensure the caller is the LayerZero V2 Endpoint
        require(msg.sender == LAYER_ZERO_V2_ENDPOINT, NotFromLzV2Endpoint());

        // Extract the compose message from the _message
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);
        uint256 tokenAmountBridged = OFTComposeMsgCodec.amountLD(_message);

        // Extract the source market's hash (first 32 bytes) and ccdmBridgeNonce (following 32 bytes).
        (bytes32 sourceMarketHash, uint256 ccdmBridgeNonce) = composeMsg.readComposeMsgMetadata();

        // Get the deposit token from the LZ V2 OApp that invoked the compose call
        ERC20 depositToken = ERC20(IOFT(_from).token());
        if (address(depositToken) == address(0)) {
            // If the deposit token is the native asset, wrap the native asset, and use the wrapped token as the deposit token
            IWETH(WRAPPED_NATIVE_ASSET_TOKEN).deposit{ value: tokenAmountBridged }();
            depositToken = ERC20(WRAPPED_NATIVE_ASSET_TOKEN);
        }

        // Get the campaign corresponding to this source market hash
        DepositCampaign storage campaign = sourceMarketHashToDepositCampaign[sourceMarketHash];

        // If there is no cached Weiroll Wallet for this CCDM bridge nonce in the market, create one
        address cachedWeirollWallet = campaign.ccdmBridgeNonceToWeirollWallet[ccdmBridgeNonce];
        if (cachedWeirollWallet == address(0)) {
            cachedWeirollWallet = _createWeirollWallet(sourceMarketHash, campaign.unlockTimestamp);
            campaign.ccdmBridgeNonceToWeirollWallet[ccdmBridgeNonce] = cachedWeirollWallet;
        }

        // Get the accounting ledger for this Weiroll Wallet
        WeirollWalletAccounting storage walletAccounting = campaign.weirollWalletToAccounting[cachedWeirollWallet];

        // Execute accounting logic to keep track of each depositor's position in this wallet.
        _accountForDeposits(walletAccounting, composeMsg, depositToken, tokenAmountBridged);

        emit CCDMBridgeProcessed(sourceMarketHash, _guid, ccdmBridgeNonce, cachedWeirollWallet);
    }

    /**
     * @notice Executes the deposit scripts for the specified Weiroll Wallets.
     * @dev Can't execute unless scripts are verified.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _weirollWallets The addresses of the Weiroll wallets.
     */
    function executeDepositRecipes(bytes32 _sourceMarketHash, address[] calldata _weirollWallets) external onlyCampaignOwner(_sourceMarketHash) nonReentrant {
        // Get the campaign's receipt token and deposit recipe
        DepositCampaign storage campaign = sourceMarketHashToDepositCampaign[_sourceMarketHash];
        // Check that the campaign's deposit recipe has been verified
        require(campaign.verified, CampaignIsUnverified());

        ERC20 receiptToken = campaign.receiptToken;
        Recipe memory depositRecipe = campaign.depositRecipe;
        // Execute deposit recipes for specified wallets
        for (uint256 i = 0; i < _weirollWallets.length; ++i) {
            WeirollWallet weirollWallet = WeirollWallet(payable(_weirollWallets[i]));
            // Only execute deposit if the wallet belongs to this market and the recipe hasn't already been executed
            if (weirollWallet.marketHash() == _sourceMarketHash && !weirollWallet.executed()) {
                // Get this wallet's deposit accouting ledger
                WeirollWalletAccounting storage walletAccounting = campaign.weirollWalletToAccounting[_weirollWallets[i]];

                // Transfer input tokens from the executor into the Weiroll Wallet for use in the deposit recipe.
                _transferInputTokensToWeirollWallet(campaign.inputTokens, walletAccounting, _weirollWallets[i]);

                // Get initial receipt token balance of the Weiroll Wallet to ensure that the post-deposit balance is greater.
                uint256 initialReceiptTokenBalance = receiptToken.balanceOf(_weirollWallets[i]);

                // Execute the deposit recipe on the Weiroll wallet
                weirollWallet.executeWeiroll(depositRecipe.weirollCommands, depositRecipe.weirollState);

                // Check that receipt tokens were received on deposit
                require(receiptToken.balanceOf(_weirollWallets[i]) - initialReceiptTokenBalance > 0, MustReturnReceiptTokensOnDeposit());

                // Check that the executor has the proper allowance for the Weiroll Wallet's receipt tokens
                require(receiptToken.allowance(_weirollWallets[i], address(this)) == type(uint256).max, MustMaxAllowDepositExecutor());

                // Set once the first deposit recipe has been executed for this market
                // After this is set, campaign input tokens and the receipt token cannot be modified
                if (!sourceMarketHashToFirstDepositExecuted[_sourceMarketHash]) {
                    sourceMarketHashToFirstDepositExecuted[_sourceMarketHash] = true;
                }
            }
        }
        emit WeirollWalletsExecutedDeposits(_sourceMarketHash, _weirollWallets);
    }

    function withdraw(address _weirollWallet) external nonReentrant {
        // Instantiate Weiroll Wallet from the stored address
        WeirollWallet weirollWallet = WeirollWallet(payable(_weirollWallet));
        // Get the campaign details for the source market
        DepositCampaign storage campaign = sourceMarketHashToDepositCampaign[weirollWallet.marketHash()];

        // Checks to ensure that the withdrawal is valid
        require(campaign.verified, CampaignIsUnverified());
        require(weirollWallet.lockedUntil() <= block.timestamp, WalletLocked());

        // Get the accounting ledger for this Weiroll Wallet (amount arg is repurposed as the CCDM bridge nonce on destination)
        WeirollWalletAccounting storage walletAccounting = campaign.weirollWalletToAccounting[_weirollWallet];

        if (weirollWallet.executed()) {
            // If deposit recipe has been executed, return the depositor's share of the receipt tokens
            ERC20 receiptToken = campaign.receiptToken;

            // Calculate the receipt tokens owed to the depositor
            ERC20 firstInputToken = campaign.inputTokens[0];
            uint256 amountDeposited = walletAccounting.depositorToTokenToAmountDeposited[msg.sender][firstInputToken];
            uint256 totalAmountDeposited = walletAccounting.tokenToTotalAmountDeposited[firstInputToken];
            uint256 receiptTokensOwed = (receiptToken.balanceOf(_weirollWallet) * amountDeposited) / totalAmountDeposited;

            // Update the accounting to reflect the withdrawal
            delete walletAccounting.depositorToTokenToAmountDeposited[msg.sender][firstInputToken];
            walletAccounting.tokenToTotalAmountDeposited[firstInputToken] -= amountDeposited;

            // Remit the receipt tokens to the depositor
            receiptToken.safeTransferFrom(_weirollWallet, msg.sender, receiptTokensOwed);
        } else {
            // If it is not, the receipt token might be incorrectly set which would stop them from
            // If deposit recipe hasn't been executed, return the depositor's share of the input tokens
            for (uint256 i = 0; i < campaign.inputTokens.length; ++i) {
                // Get the amount of this input token deposited by the depositor
                ERC20 inputToken = campaign.inputTokens[i];
                uint256 amountDeposited = walletAccounting.depositorToTokenToAmountDeposited[msg.sender][inputToken];

                // Update the accounting to reflect the withdrawal
                delete walletAccounting.depositorToTokenToAmountDeposited[msg.sender][inputToken];
                walletAccounting.tokenToTotalAmountDeposited[inputToken] -= amountDeposited;

                // Transfer the amount deposited back to the depositor
                inputToken.safeTransfer(msg.sender, amountDeposited);
            }
        }

        emit DepositorWithdrawn(_weirollWallet, msg.sender);
    }

    /**
     * @notice Returns the hash of the campaign parameters which must be used to check against the current parameters on verifiaction.
     * @return scriptVerificationHash The hash of the encoded input tokens, receipt token, and deposit recipe.
     */
    function getScriptVerificationHash(bytes32 _sourceMarketHash) public returns (bytes32 scriptVerificationHash) {
        DepositCampaign storage campaign = sourceMarketHashToDepositCampaign[_sourceMarketHash];
        scriptVerificationHash = keccak256(abi.encode(campaign.inputTokens, campaign.receiptToken, campaign.depositRecipe));
    }

    /*//////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Creates a Weiroll wallet with the specified parameters.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _unlockTimestamp The ABSOLUTE unlock timestamp for this Weiroll Wallet.
     * @return weirollWallet The address of the Weiroll wallet.
     */
    function _createWeirollWallet(bytes32 _sourceMarketHash, uint256 _unlockTimestamp) internal returns (address payable weirollWallet) {
        // Deploy a fresh, non-forfeitable Weiroll Wallet with immutable args.
        weirollWallet = payable(
            WEIROLL_WALLET_IMPLEMENTATION.clone(
                abi.encodePacked(
                    address(0), // Wallet owner will be zero address so that no single party can siphon depositor funds after lock timestamp has passed.
                    address(this), // DepositExecutor will be the entrypoint for recipe execution (in addition to the owner after the unlock timestamp).
                    uint256(0), // Amount will always be 0 since a Weiroll Wallet may hold multiple tokens.
                    _unlockTimestamp, // The ABSOLUTE unlock timestamp for wallets created for this campaign.
                    false, // Weiroll Wallet is non-forfeitable since the deposits have reached the destination chain.
                    _sourceMarketHash // The source market hash and its corresponding campaign identifier that this wallet belongs to.
                )
            )
        );
    }

    /**
     * @notice Accounts for deposits by parsing the compose message and updating the Weiroll Wallet's accounting information.
     * @dev Processes the compose message to extract depositor addresses and deposit amounts, ensuring that the total deposits accounted for do not exceed the
     * amount bridged.
     * @dev Updates the wallet info with each depositor's deposited amounts and the total deposited amounts for the token.
     * @param _walletAccounting The storage reference to the Weiroll wallet information to be updated.
     * @param _composeMsg The compose message containing depositor addresses and deposit amounts.
     * @param _depositToken The ERC20 token that was deposited.
     * @param _tokenAmountBridged The total amount of tokens that were bridged and available for deposits.
     * @custom:error CantAccountForMoreDepositsThanBridged Thrown if the total deposits accounted for exceed the amount bridged.
     */
    function _accountForDeposits(
        WeirollWalletAccounting storage _walletAccounting,
        bytes memory _composeMsg,
        ERC20 _depositToken,
        uint256 _tokenAmountBridged
    )
        internal
    {
        // Amount of deposits accounted for so far
        uint256 depositsAccountedFor = 0;

        // Initialize offset to start after the payload's metadata
        uint256 offset = CCDMPayloadLib.METADATA_SIZE;

        while (offset + CCDMPayloadLib.BYTES_PER_DEPOSITOR <= _composeMsg.length) {
            // Extract Depositor/AP address (20 bytes)
            address depositor = _composeMsg.readAddress(offset);
            offset += 20;

            // Extract deposit amount (12 bytes)
            uint96 depositAmount = _composeMsg.readUint96(offset);
            offset += 12;

            // Update total amount deposited
            depositsAccountedFor += depositAmount;
            require(depositsAccountedFor <= _tokenAmountBridged, CantAccountForMoreDepositsThanBridged());

            // Update the accounting to reflect the deposit
            _walletAccounting.depositorToTokenToAmountDeposited[depositor][_depositToken] += depositAmount;
            _walletAccounting.tokenToTotalAmountDeposited[_depositToken] += depositAmount;
        }
    }

    /**
     * @notice Transfers input tokens from the contract to the specified Weiroll Wallet.
     * @param _inputTokens The list of input tokens to transfer.
     * @param _walletAccounting The ledger associated with the Weiroll Wallet.
     * @param _weirollWallet The address of the Weiroll Wallet.
     */
    function _transferInputTokensToWeirollWallet(
        ERC20[] storage _inputTokens,
        WeirollWalletAccounting storage _walletAccounting,
        address _weirollWallet
    )
        internal
    {
        for (uint256 i = 0; i < _inputTokens.length; ++i) {
            ERC20 inputToken = _inputTokens[i];

            // Get total amount of this token deposited into the Weiroll Wallet
            uint256 amountOfTokenDepositedIntoWallet = _walletAccounting.tokenToTotalAmountDeposited[inputToken];

            // Transfer amount of the input token into the Weiroll Wallet
            inputToken.safeTransfer(_weirollWallet, amountOfTokenDepositedIntoWallet);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        Administrative Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the script verifier address.
     * @param _scriptVerifier The address of the script verifier.
     */
    function setScriptVerifier(address _scriptVerifier) external onlyOwner {
        scriptVerifier = _scriptVerifier;
        emit ScriptVerifierSet(_scriptVerifier);
    }

    /**
     * @notice Sets a new owner for the specified campaign.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _owner The address of the campaign owner.
     */
    function setNewCampaignOwner(bytes32 _sourceMarketHash, address _owner) external onlyCampaignOwnerOrDepositExecutorOwner(_sourceMarketHash) {
        sourceMarketHashToDepositCampaign[_sourceMarketHash].owner = _owner;
        emit CampaignOwnerSet(_sourceMarketHash, _owner);
    }

    /**
     * @notice Verifies any updates to a campaign's input tokens, receipt token, and deposit recipe.
     * @notice Deposit Recipe can now be executed and withdrawals can be made.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _scriptVerificationHash The hash of the campaign parameters to verify - prevents token/script setting frontrunning attacks by the campaign owner.
     */
    function verifyCampaign(bytes32 _sourceMarketHash, bytes32 _scriptVerificationHash) external onlyScriptVerifier {
        if (_scriptVerificationHash == getScriptVerificationHash(_sourceMarketHash)) {
            sourceMarketHashToDepositCampaign[_sourceMarketHash].verified = true;
            emit ScriptVerificationStatusUpdated(_sourceMarketHash, true);
        }
    }

    /**
     * @notice Sets the campaign verification status to false.
     * @notice Deposit Recipe cannot be executed and withdrawals are blocked until verified.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     */
    function unverifyCampaign(bytes32 _sourceMarketHash) external onlyScriptVerifier {
        delete sourceMarketHashToDepositCampaign[_sourceMarketHash].verified;
        emit ScriptVerificationStatusUpdated(_sourceMarketHash, false);
    }

    /**
     * @notice Sets the unlock timestamp for a Deposit Campaign.
     * @notice The unlock timestamp can only be set once per campaign.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _unlockTimestamp The ABSOLUTE timestamp until deposits will be locked for this campaign.
     */
    function setCampaignUnlockTimestamp(bytes32 _sourceMarketHash, uint256 _unlockTimestamp) external onlyCampaignOwner(_sourceMarketHash) {
        require(sourceMarketHashToDepositCampaign[_sourceMarketHash].unlockTimestamp == 0, CampaignUnlockTimestampCanOnlyBeSetOnce());
        sourceMarketHashToDepositCampaign[_sourceMarketHash].unlockTimestamp = _unlockTimestamp;
        emit CampaignUnlockTimestampSet(_sourceMarketHash, _unlockTimestamp);
    }

    /**
     * @notice Sets the input tokens of a Deposit Campaign.
     * @dev Once the first deposit recipe for a campaign has been executed, the input tokens are immutable.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _inputTokens The input tokens to set for this deposit campaign.
     */
    function setCampaignInputTokens(bytes32 _sourceMarketHash, ERC20[] calldata _inputTokens) external onlyCampaignOwner(_sourceMarketHash) {
        if (!sourceMarketHashToFirstDepositExecuted[_sourceMarketHash]) {
            sourceMarketHashToDepositCampaign[_sourceMarketHash].inputTokens = _inputTokens;
            emit CampaignInputTokensSet(_sourceMarketHash, _inputTokens);
        }
    }

    /**
     * @notice Sets the receipt token of a Deposit Campaign.
     * @dev Once the first deposit recipe for a campaign has been executed, the receipt token is immutable.
     * @dev The receipt token MUST be returned to the Weiroll Wallet upon executing the deposit recipe.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _receiptToken The receipt token to set for this deposit campaign.
     */
    function setCampaignReceiptToken(bytes32 _sourceMarketHash, ERC20 _receiptToken) external onlyCampaignOwner(_sourceMarketHash) {
        if (!sourceMarketHashToFirstDepositExecuted[_sourceMarketHash]) {
            sourceMarketHashToDepositCampaign[_sourceMarketHash].receiptToken = _receiptToken;
            emit CampaignReceiptTokenSet(_sourceMarketHash, _receiptToken);
        }
    }

    /**
     * @notice Sets the deposit recipe of a Deposit Campaign.
     * @dev Automatically unverifies a campaign. Must be reverified in order to execute the deposit recipe or process withdrawals.
     * @dev The deposit recipe MUST give the DepositExecutor max approval on the campaign's receipt token for the Weiroll Wallet.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _depositRecipe The deposit recipe for the campaign on the destination chain.
     */
    function setCampaignDepositRecipe(bytes32 _sourceMarketHash, Recipe calldata _depositRecipe) external onlyCampaignOwner(_sourceMarketHash) {
        sourceMarketHashToDepositCampaign[_sourceMarketHash].depositRecipe = _depositRecipe;
        delete sourceMarketHashToDepositCampaign[_sourceMarketHash].verified;
        emit CampaignDepositRecipeSet(_sourceMarketHash);
    }
}
