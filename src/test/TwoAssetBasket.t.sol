// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.16;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {TestPlus} from "./TestPlus.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";
import {Dollar} from "src/libs/DollarMath.sol";
import {TwoAssetBasket} from "src/vaults/TwoAssetBasket.sol";
import {Router} from "src/vaults/cross-chain-vault/router/Router.sol";
import {IERC4626} from "src/interfaces/IERC4626.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

/// @notice Test two asset basket functionalities.
contract BtcEthBasketTest is TestPlus {
    TwoAssetBasket basket;
    Router router;
    ERC20 usdc = ERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    ERC20 btc;
    ERC20 weth;

    function setUp() public {
        forkPolygon();

        basket = Deploy.deployTwoAssetBasket(usdc);
        router = new Router("Alp", IWETH(address(0)));
        btc = basket.btc();
        weth = basket.weth();
    }

    function mockUSDCPrice() internal {
        vm.mockCall(
            address(basket.tokenToOracle(basket.asset())),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), uint256(1e8), 0, block.timestamp, uint80(1))
        );
    }

    /// @notice Test depositing and withdrawing form the basket works.
    function testDepositWithdraw() public {
        // mint some usdc, can remove hardcoded selector later
        uint256 mintAmount = 200 * 1e6;
        deal(address(usdc), address(this), mintAmount, true);
        usdc.approve(address(basket), type(uint256).max);
        basket.deposit(mintAmount, address(this));

        // you receive the dollar value of the amount of btc/eth deposited into the basket
        // the testnet usdc/btc usdc/eth pools do not have accurate prices
        assertTrue(basket.balanceOf(address(this)) > 0);
        uint256 vaultTVL = Dollar.unwrap(basket.valueOfVault());
        assertEq(basket.balanceOf(address(this)), (vaultTVL * 1e10) / 100);

        emit log_named_uint("VALUE OF VAULT", vaultTVL);
        emit log_named_uint("Initial AlpLarge price: ", basket.detailedPrice().num);

        uint256 inputReceived = basket.withdraw((mintAmount * 90) / 100, address(this), address(this));
        emit log_named_uint("DOLLARS WITHDRAWN: ", inputReceived);
    }

    /// @notice Test redeeming form the basket works.
    function testRedeem() public {
        mockUSDCPrice();

        // give vault some btc/eth
        deal(address(btc), address(basket), 1e18);
        deal(address(weth), address(basket), 10e18);

        // Give us 50% of shares
        deal(address(basket), address(this), 1e18, true);
        deal(address(basket), alice, 1e18, true);

        // We sold approximately half of the assets in the vault
        uint256 oldTVL = Dollar.unwrap(basket.valueOfVault());
        uint256 assetsReceived = basket.redeem(1e18, address(this), address(this));
        assertTrue(assetsReceived > 0);
        assertApproxEqRel(Dollar.unwrap(basket.valueOfVault()), oldTVL / 2, 1e18 / 1);
    }

    /// @notice Test withdrawing max amount works.
    function testMaxWithdraw() public {
        uint256 mintAmount = 100 * 1e6;
        deal(address(usdc), alice, mintAmount, true);
        deal(address(usdc), address(this), mintAmount, true);

        vm.startPrank(alice);
        usdc.approve(address(basket), type(uint256).max);
        basket.deposit(mintAmount, alice);
        vm.stopPrank();

        usdc.approve(address(basket), type(uint256).max);
        basket.deposit(mintAmount, address(this));

        emit log_named_uint("alices shares: ", basket.balanceOf(alice));
        emit log_named_uint("num shares: ", basket.balanceOf(address(this)));

        // Shares are $1 but have 18 decimals. Input asset only has  6 decimals
        basket.withdraw(basket.balanceOf(address(this)) / 1e12, address(this), address(this));
        emit log_named_uint("my shares: ", basket.balanceOf(address(this)));
        emit log_named_uint("valueOfVault: ", Dollar.unwrap(basket.valueOfVault()));
        emit log_named_uint("TotalSupplyOfVault: ", basket.totalSupply());
    }

    /// @notice Test that slippage parameter while depositing works.
    function testDepositSlippage() public {
        // The initial deposit gives as many shares as dollars deposited in the vault
        // If we expect 10 shares but only deposit 1 dollar, this will revert
        uint256 minShares = 10 * 10 ** 18;
        deal(address(usdc), address(this), 1e6);
        usdc.approve(address(basket), type(uint256).max);

        vm.expectRevert("TAB: min shares");
        basket.deposit(1e6, address(this), minShares);

        basket.deposit(1e6, address(this), 0);
    }

    /// @notice Test that slippage parameter while withdrawing works.
    function testWithdrawSlippage() public {
        deal(address(usdc), address(this), 10e6);
        usdc.approve(address(basket), type(uint256).max);

        basket.deposit(10e6, address(this), 0);

        vm.expectRevert("TAB: max shares");
        basket.withdraw(1e6, address(this), address(this), 0);

        // If we set max shares to infinite the withdrawal will work
        basket.withdraw(1e6, address(this), address(this), type(uint256).max);
    }

    /// @notice Test that slippage parameter while redeeming works.
    function testRedeemSlippage() public {
        deal(address(usdc), address(this), 1e6);
        usdc.approve(address(basket), type(uint256).max);

        uint256 shares = basket.deposit(1e6, address(this), 0);

        vm.expectRevert("TAB: min assets");
        basket.redeem(shares - 10, address(this), address(this), type(uint256).max);

        basket.redeem(shares, address(this), address(this), 0);
    }

    /// @notice Fuzz test for selling when there is random imbalance in BTC and ETH balanace.
    function testBuySplitsFuzz(uint256 balBtc, uint256 balEth) public {
        //	Let balances vary
        // 10k BTC is about 200M at todays prices, same for 133,000 ETH
        balBtc = bound(balBtc, 0, 10_000 * 1e18);
        balEth = bound(balEth, 0, 133e3 * 1e18);
        deal(address(btc), address(basket), balBtc);
        deal(address(weth), address(basket), balEth);

        // Test that if you are far from ideal amount, then we buy just one asset

        // Calculate idealAmount of Btc
        uint256 r1 = basket.ratios(0);
        uint256 r2 = basket.ratios(1);
        uint256 vaultDollars = Dollar.unwrap(basket.valueOfVault());
        uint256 idealBtcDollars = (r1 * (vaultDollars)) / (r1 + r2);
        uint256 idealEthDollars = vaultDollars - idealBtcDollars;

        (Dollar rawBtcDollars, Dollar rawEthDollars) = basket._valueOfVaultComponents();
        uint256 btcDollars = Dollar.unwrap(rawBtcDollars);
        uint256 ethDollars = Dollar.unwrap(rawEthDollars);

        uint256 amountInput = 100e6; // 100 USDC.
        (uint256 assetsToBtc, uint256 assetsToEth) = basket._getBuySplits(amountInput);
        uint256 inputDollars = amountInput * 1e2; // 100 usdc with 8 decimals
        if (btcDollars + inputDollars < idealBtcDollars) {
            // We buy just btc
            assertEq(assetsToBtc, amountInput);
            assertEq(assetsToEth, 0);
        } else if (ethDollars + inputDollars < idealEthDollars) {
            // We buy just eth
            assertEq(assetsToBtc, 0);
            assertEq(assetsToEth, amountInput);
        } else {
            // If you are close to ideal amount, then we buy some of both asset
            assertTrue(assetsToBtc > 0);
            assertTrue(assetsToEth > 0);
        }
    }

    /// @notice Test buying when there is imbalance in BTC and ETH balanace
    function testBuySplits() public {
        // We have too much eth, so we only buy btc
        // Mocking balanceOf. Not using encodeCall because ERC20.balanceOf can't be found by solc
        vm.mockCall(
            address(weth), abi.encodeWithSelector(0x70a08231, address(basket)), abi.encode(100 * 10 ** weth.decimals())
        );

        uint256 amountInput = 100e6; // 100 USDC.
        (uint256 assetsToBtc, uint256 assetsToEth) = basket._getBuySplits(amountInput);

        assertEq(assetsToBtc, amountInput);
        assertEq(assetsToEth, 0);

        // We have too much btc so we only buy eth
        vm.clearMockedCalls();
        vm.mockCall(
            address(basket.btc()),
            abi.encodeWithSelector(0x70a08231, address(basket)),
            abi.encode(100 * 10 ** btc.decimals())
        );

        (assetsToBtc, assetsToEth) = basket._getBuySplits(amountInput);

        assertEq(assetsToBtc, 0);
        assertEq(assetsToEth, amountInput);

        // We have some of both, so we buy until we hit the ratios
        // The btc/eth ratio at the pinned block is ~0.08, so if we pick 0.1 we have roughly equal value
        vm.clearMockedCalls();
        vm.mockCall(
            address(btc), abi.encodeWithSelector(0x70a08231, address(basket)), abi.encode(1 * 10 ** btc.decimals())
        );
        vm.mockCall(
            address(weth), abi.encodeWithSelector(0x70a08231, address(basket)), abi.encode(10 ** weth.decimals())
        );

        // We have a split that is more even than 1:2
        uint256 largeInput = 100e6 * 1e6;
        (assetsToBtc, assetsToEth) = basket._getBuySplits(largeInput);
        assertTrue(assetsToBtc > largeInput / 3);
        assertTrue(assetsToEth > largeInput / 3);
    }

    /// @notice Test selling when there is imbalance in BTC and ETH balanace.
    function testSellSplits() public {
        // We have too much btc, so we only sell it
        // Mocking balanceOf. Not using encodeCall because ERC20.balanceOf can't be found by solc
        vm.mockCall(
            address(basket.btc()), abi.encodeWithSelector(0x70a08231, address(basket)), abi.encode(10 ** btc.decimals())
        );
        mockUSDCPrice();

        uint256 amountInput = 100e6; // 100 USDC.
        (Dollar rawDollarsFromBtc, Dollar rawDollarsFromEth) = basket._getSellSplits(amountInput);
        uint256 dollarsFromBtc = Dollar.unwrap(rawDollarsFromBtc);
        uint256 dollarsFromEth = Dollar.unwrap(rawDollarsFromEth);

        assertEq(dollarsFromBtc, amountInput * 1e2);
        assertEq(dollarsFromEth, 0);

        // We have too much eth so we only sell eth
        vm.clearMockedCalls();
        vm.mockCall(
            address(basket.weth()),
            abi.encodeWithSelector(0x70a08231, address(basket)),
            abi.encode(100 ** weth.decimals())
        );
        mockUSDCPrice();
        (rawDollarsFromBtc, rawDollarsFromEth) = basket._getSellSplits(amountInput);
        dollarsFromBtc = Dollar.unwrap(rawDollarsFromBtc);
        dollarsFromEth = Dollar.unwrap(rawDollarsFromEth);

        assertEq(dollarsFromBtc, 0);
        assertEq(dollarsFromEth, amountInput * 1e2);

        // // We have some of both, so we buy until we hit the ratios
        // See notes on how these values were chosen in testBuySplits
        vm.clearMockedCalls();
        vm.mockCall(
            address(basket.btc()), abi.encodeWithSelector(0x70a08231, address(basket)), abi.encode(10 ** btc.decimals())
        );
        vm.mockCall(
            address(basket.weth()),
            abi.encodeWithSelector(0x70a08231, address(basket)),
            abi.encode(10 * 10 ** weth.decimals())
        );
        mockUSDCPrice();

        // We have a split that is more even than 1:2
        uint256 largeInput = 100e6 * 1e6;
        (rawDollarsFromBtc, rawDollarsFromEth) = basket._getSellSplits(largeInput);
        dollarsFromBtc = Dollar.unwrap(rawDollarsFromBtc);
        dollarsFromEth = Dollar.unwrap(rawDollarsFromEth);
        assertTrue(dollarsFromBtc > (largeInput * 1e2) / 3);
        assertTrue(dollarsFromEth > (largeInput * 1e2) / 3);
    }

    /// @notice Test that pausing the basket works.
    function testVaultPause() public {
        vm.prank(governance);
        basket.pause();

        vm.expectRevert("Pausable: paused");
        basket.deposit(1e18, address(this));

        vm.expectRevert("Pausable: paused");
        basket.withdraw(1e18, address(this), address(this));

        vm.prank(governance);
        basket.unpause();
        testDepositWithdraw();
    }

    /// @notice Test view functions for detailed prices.
    function testDetailedPrice() public {
        // This function should work even if there is nothing in the vault
        TwoAssetBasket.Number memory price = basket.detailedPrice();
        assertEq(price.num, 100e8);

        address user = address(this);
        deal(address(usdc), user, 2e6);
        usdc.approve(address(basket), type(uint256).max);

        basket.deposit(1e6, user);
        deal(address(usdc), address(basket), 1e18);
        TwoAssetBasket.Number memory price2 = basket.detailedPrice();
        assertGt(price2.num, 10 ** 8);
    }
}
