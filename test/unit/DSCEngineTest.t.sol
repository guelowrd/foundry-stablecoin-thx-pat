// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public immutable USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL_REDEEMED = 0.03 ether;
    uint256 public constant AMOUNT_DSC_MINTED = 2000 * 0.05 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    // Liquidation
    address public immutable LIQUIDATOR = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, , weth, , ) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        (btcUsdPriceFeed, , wbtc, , ) = config.activeNetworkConfig();
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    /////////////////
    // Price Tests //
    /////////////////
    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////
    function testRevertsIfZeroCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranTokenMock = new ERC20Mock();
        ranTokenMock.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(ranTokenMock), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine
            .getAccountInfo(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ///////////////////
    // mintDsc Tests //
    ///////////////////
    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            AMOUNT_DSC_MINTED
        );
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndMintDsc()
        public
        depositedCollateralAndMintedDsc
    {
        (uint256 totalDscMinted, ) = dscEngine.getAccountInfo(USER);
        uint256 expectedDscMinted = AMOUNT_DSC_MINTED;
        assertEq(totalDscMinted, expectedDscMinted);
    }

    function testCanDepositCollateralAndRevertsWhenTryingToMintTooMuchDsc()
        public
    {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        uint256 amountDscToMint = dscEngine.getUsdValue(
            weth,
            AMOUNT_COLLATERAL
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__HealthFactorIsBroken.selector,
                (dscEngine.getMinHealthFactor() *
                    dscEngine.getLiquidationThreshold()) /
                    dscEngine.getLiquidationPrecision()
            )
        );
        dscEngine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountDscToMint
        );
        vm.stopPrank();
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        uint256 amountToMint = (AMOUNT_COLLATERAL *
            (uint256(price) * dscEngine.getAdditionalFeedPrecision())) /
            dscEngine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(
            amountToMint,
            dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__HealthFactorIsBroken.selector,
                expectedHealthFactor
            )
        );
        dscEngine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.stopPrank();
    }

    ////////////////////////////
    // redeemCollateral Tests //
    ////////////////////////////
    function testCanDepositCollateralMintDscAndRedeemCollateralForDsc()
        public
        depositedCollateralAndMintedDsc
    {
        vm.startPrank(USER);
        uint256 amountDscToBurn = AMOUNT_DSC_MINTED;
        dsc.approve(address(dscEngine), amountDscToBurn);
        dscEngine.redeemCollateralForDsc(
            weth,
            AMOUNT_COLLATERAL_REDEEMED,
            amountDscToBurn
        );
        (uint256 totalDscMinted, uint256 actualCollateralRemaining) = dscEngine
            .getAccountInfo(USER);
        uint256 expectedDscMinted = AMOUNT_DSC_MINTED - amountDscToBurn;
        uint256 expectedCollateralRemaining = dscEngine.getUsdValue(
            weth,
            AMOUNT_COLLATERAL - AMOUNT_COLLATERAL_REDEEMED
        );
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(actualCollateralRemaining, expectedCollateralRemaining);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////
    function testCantLiquidateGoodHealthFactor()
        public
        depositedCollateralAndMintedDsc
    {
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            collateralToCover,
            AMOUNT_DSC_MINTED
        );
        dsc.approve(address(dscEngine), AMOUNT_DSC_MINTED);

        console.log("user health factor: ", dscEngine.getHealthFactor(USER));
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, AMOUNT_DSC_MINTED);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            AMOUNT_DSC_MINTED
        );
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            collateralToCover,
            AMOUNT_DSC_MINTED
        );
        dsc.approve(address(dscEngine), AMOUNT_DSC_MINTED);
        dscEngine.liquidate(weth, USER, AMOUNT_DSC_MINTED); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = dscEngine.getTokenAmountFromUsd(
            weth,
            AMOUNT_DSC_MINTED
        ) +
            (dscEngine.getTokenAmountFromUsd(weth, AMOUNT_DSC_MINTED) /
                dscEngine.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    // TODO: more tests to write, check `forge coverage --report debug` to see precisely which lines are untested.
}
