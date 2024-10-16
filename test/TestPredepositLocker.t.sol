// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the PredepositLocker contract and its dependencies
import { PredepositLocker, RecipeMarketHubBase, ERC20 } from "src/PredepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, RewardStyle, Points } from "test/utils/RecipeMarketHubTestBase.sol";
import { IStargate } from "src/interfaces/IStargate.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { WeirollWalletHelper } from "test/utils/WeirollWalletHelper.sol";

// Test depositing and withdrawing to/from the PredepositLocker through a Royco Market
// This will simulate the expected behaviour on the source chain of a Predeposit Campaign
contract TestPredepositLocker is RecipeMarketHubTestBase {
    using FixedPointMathLib for uint256;

    address IP_ADDRESS;
    address AP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    ERC20[] public predepositTokens;
    IStargate[] public stargates;

    PredepositLocker predepositLocker;
    WeirollWalletHelper walletHelper;

    uint256 frontendFee;
    bytes32 marketHash;

    function setUp() external {
        walletHelper = new WeirollWalletHelper();

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        AP_ADDRESS = BOB_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

        predepositLocker = new PredepositLocker(OWNER_ADDRESS, 0, address(0), predepositTokens, stargates, recipeMarketHub);

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(PredepositLocker.deposit.selector, address(walletHelper), address(mockLiquidityToken), address(predepositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(PredepositLocker.withdraw.selector, address(predepositLocker));

        frontendFee = recipeMarketHub.minimumFrontendFee();
        marketHash = recipeMarketHub.createMarket(address(mockLiquidityToken), 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);
    }

    function test_depositIntoPredepositLocker(uint256 offerAmount, uint256 fillAmount) external {
        vm.assume(fillAmount <= offerAmount && fillAmount > 1e18);
        vm.assume(offerAmount < type(uint96).max && offerAmount > 1e18);

        assertEq(mockLiquidityToken.balanceOf(address(predepositLocker)), 0);

        // Mint liquidity tokens to the AP to fill the offer
        mockLiquidityToken.mint(AP_ADDRESS, fillAmount);
        vm.startPrank(AP_ADDRESS);
        mockLiquidityToken.approve(address(recipeMarketHub), fillAmount);
        vm.stopPrank();

        // Create a fillable IP offer for points
        (bytes32 offerHash, Points points) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        vm.expectEmit(false, true, false, false, address(mockLiquidityToken));
        emit ERC20.Transfer(address(0), address(predepositLocker), fillAmount);

        vm.expectEmit(true, false, false, false, address(predepositLocker));
        emit PredepositLocker.UserDeposited(marketHash, address(0), fillAmount);

        // Record the logs to capture Transfer events to get Weiroll wallet address
        vm.recordLogs();
        // AP Fills the offer (no funding vault)
        vm.startPrank(AP_ADDRESS);
        recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
        vm.stopPrank();

        // Extract the Weiroll wallet address (the 'to' address from the Transfer event - third event in logs)
        address weirollWallet = address(uint160(uint256(vm.getRecordedLogs()[0].topics[2])));

        assertEq(mockLiquidityToken.balanceOf(weirollWallet), 0);
        assertEq(mockLiquidityToken.balanceOf(address(predepositLocker)), fillAmount);
    }

    // Get fill amount using Weiroll Helper -> Approve fill amount -> Call Deposit
    function _buildDepositRecipe(
        bytes4 _depositSelector,
        address _helper,
        address _tokenAddress,
        address _predepositLocker
    )
        internal
        pure
        returns (RecipeMarketHubBase.Recipe memory)
    {
        bytes32[] memory commands = new bytes32[](3);
        bytes[] memory state = new bytes[](2);

        state[0] = abi.encode(_predepositLocker);

        // GET FILL AMOUNT

        // DELEGATECALL
        uint8 f = uint8(0x00);

        // Input list: No arguments (END_OF_ARGS = 0xff)
        bytes6 inputData = hex"ffffffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        uint8 o = 0x01;

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[0] = (bytes32(abi.encodePacked(WeirollWalletHelper.amount.selector, f, inputData, o, _helper)));

        // APPROVE Predeposit Locker to spend tokens

        // CALL
        f = uint8(0x01);

        // Input list: Args at state index 0 (address) and args at state index 1 (fill amount)
        inputData = hex"0001ffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        o = 0xff;

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[1] = (bytes32(abi.encodePacked(ERC20.approve.selector, f, inputData, o, _tokenAddress)));

        // CALL DEPOSIT() in Predeposit Locker
        f = uint8(0x01);

        // Input list: No arguments (END_OF_ARGS = 0xff)
        inputData = hex"ffffffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        o = uint8(0xff);

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[2] = (bytes32(abi.encodePacked(_depositSelector, f, inputData, o, _predepositLocker)));

        return RecipeMarketHubBase.Recipe(commands, state);
    }

    function _buildWithdrawalRecipe(bytes4 _withdrawalSelector, address _predepositLocker) internal pure returns (RecipeMarketHubBase.Recipe memory) {
        bytes32[] memory commands = new bytes32[](1);
        bytes[] memory state = new bytes[](0);

        // Flags:
        // DELEGATECALL (calltype = 0x00)
        // CALL (calltype = 0x01)
        // STATICCALL (calltype = 0x02)
        // CALL with value (calltype = 0x03)
        uint8 f = uint8(0x01);

        // Input list: No arguments (END_OF_ARGS = 0xff)
        bytes6 inputData = hex"ffffffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        uint8 o = uint8(0xff);

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[0] = (bytes32(abi.encodePacked(_withdrawalSelector, f, inputData, o, _predepositLocker)));

        return RecipeMarketHubBase.Recipe(commands, state);
    }
}