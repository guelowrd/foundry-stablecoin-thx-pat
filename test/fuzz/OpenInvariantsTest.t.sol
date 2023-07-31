// SPDX-License-Identifier: MIT

// Have our invariant aka properties
// What are our invariants?
// 1. The total supply of tokens is always less than the total value of collateral
// 2. Getter/view functions should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (, , weth, wbtc, ) = config.activeNetworkConfig();
        targetContract(address(dscEngine));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of all the collateral
        // compare it to all the debt (= all dsc minted)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

        uint256 totalWethValue = dscEngine.getUsdValue(
            weth,
            totalWethDeposited
        );
        uint256 totalWbtcValue = dscEngine.getUsdValue(
            wbtc,
            totalWbtcDeposited
        );
        console.log("totalWethValue", totalWethValue);
        console.log("totalWbtcValue", totalWethValue);
        console.log("totalSupply", totalWethValue);
        assert(totalWethValue + totalWbtcValue >= totalSupply);
    }
}
