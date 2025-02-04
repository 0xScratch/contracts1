// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.16;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {TestPlus} from "./TestPlus.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestStrategy, TestStrategyDivestSlippage} from "./mocks/TestStrategy.sol";

import {BridgeEscrow} from "src/vaults/cross-chain-vault/escrow/BridgeEscrow.sol";
import {IWormhole} from "src/interfaces/IWormhole.sol";
import {BaseStrategy} from "src/strategies/BaseStrategy.sol";
import {BaseVault} from "src/vaults/cross-chain-vault/BaseVault.sol";
import {AffineVault} from "src/vaults/AffineVault.sol";

contract BaseVaultLiquidate is BaseVault {
    function liquidate(uint256 amount) public returns (uint256) {
        return _liquidate(amount);
    }

    // We override this function and remove the "onlyInitializing" modifier so
    // we can directly call it in `setUp`

    // NOTE: If foundry made it easy to mock modifiers or write to packed storage slots
    // (we would like to set `_initializing` to true => see Initializable.sol)
    // then we wouldn't need to do this
    function baseInitializeMock(
        address _governance,
        ERC20 vaultAsset,
        address _wormholeRouter,
        BridgeEscrow _bridgeEscrow
    ) external {
        baseInitialize(_governance, vaultAsset, _wormholeRouter, _bridgeEscrow);
    }
}

contract AffineVaultLiquidate is AffineVault {
    function liquidate(uint256 amount) public returns (uint256) {
        return _liquidate(amount);
    }

    function initialize(address _governance, ERC20 vaultAsset) external initializer {
        baseInitialize(_governance, vaultAsset);
    }
}

/// @notice Test general functionalities of vaults.
abstract contract CommonVaultTestSuite is TestPlus {
    using stdStorage for StdStorage;

    MockERC20 token;
    BaseVaultLiquidate vault;
    uint8 constant MAX_STRATEGIES = 20;

    /// @notice Test harvesting strategies and makes sure locked profit works.
    function testHarvest() public {
        BaseStrategy newStrategy1 = new TestStrategy(AffineVault(address(vault)));
        vault.addStrategy(newStrategy1, 1000);
        token.mint(address(newStrategy1), 1000);
        assertTrue(newStrategy1.balanceOfAsset() != 0);
        BaseStrategy[] memory strategies = new BaseStrategy[](1);
        strategies[0] = newStrategy1;
        vm.warp(vault.lastHarvest() + vault.LOCK_INTERVAL() + 1);
        vault.harvest(strategies);
        vm.warp(vault.lastHarvest() + vault.LOCK_INTERVAL() + 1);
        assert(vault.vaultTVL() == 1000);
        assert(vault.lockedProfit() == 0);
    }

    /// @notice Test addition to new strategy works.
    function testStrategyAddition() public {
        TestStrategy strategy = new TestStrategy(AffineVault(address(vault)));
        vault.addStrategy(strategy, 1000);
        assertEq(address(vault.withdrawalQueue(0)), address(strategy));
        (, uint256 tvlBps,) = vault.strategies(strategy);
        assertEq(tvlBps, 1000);
    }

    /// @notice Test removal of strategies work.
    function testStrategyRemoval() public {
        // Adding a strategy increases our totalBps
        TestStrategy strategy = new TestStrategy(AffineVault(address(vault)));
        vault.addStrategy(strategy, 1000);
        assertEq(vault.totalBps(), 1000);

        // Removing a strategy decreases our totalBps
        vault.removeStrategy(strategy);
        assertTrue(vault.totalBps() == 0);

        (bool isActive, uint256 tvlBps,) = vault.strategies(strategy);

        assertEq(tvlBps, 0);
        assertTrue(isActive == false);
        assertEq(address(vault.withdrawalQueue(0)), address(0));
    }

    /// @notice Test divesting of funds work after a strategy is removed from withdrawal queue.
    function testRemoveStrategyAndDivest() public {
        // Add strategy
        TestStrategy strategy = new TestStrategy(AffineVault(address(vault)));
        vault.addStrategy(strategy, 1000);

        // Give strategy money
        token.mint(address(strategy), 1000);

        // Harvest
        BaseStrategy[] memory strategies = new BaseStrategy[](1);
        strategies[0] = strategy;
        vm.warp(vault.lastHarvest() + vault.LOCK_INTERVAL() + 1);
        vault.harvest(strategies);

        // Divest (make sure divest is called on the strategy)
        vm.expectCall(address(strategy), abi.encodeCall(BaseStrategy.divest, (strategy.totalLockedValue())));
        vault.removeStrategy(strategy);

        // The vault removed all money from the strategy
        assertTrue(token.balanceOf(address(strategy)) == 0);
    }

    /// @notice Test getter for withdrwal queue.
    function testGetWithdrawalQueue() public {
        for (uint256 i = 0; i < MAX_STRATEGIES; ++i) {
            vault.addStrategy(new TestStrategy(AffineVault(address(vault))), 10);
        }
        for (uint256 i = 0; i < MAX_STRATEGIES; ++i) {
            assertTrue(vault.getWithdrawalQueue()[i] == vault.withdrawalQueue(i));
        }
    }

    event WithdrawalQueueIndexesSwapped(
        uint256 index1, uint256 index2, BaseStrategy indexed newStrategy1, BaseStrategy indexed newStrategy2
    );

    /// @notice Test setter for withdrawal queue.
    function testSetWithdrawalQueue() public {
        BaseStrategy[MAX_STRATEGIES] memory newQueue;
        for (uint256 i = 0; i < MAX_STRATEGIES; ++i) {
            newQueue[i] = new TestStrategy(AffineVault(address(vault)));
        }
        vault.setWithdrawalQueue(newQueue);
        for (uint256 i = 0; i < MAX_STRATEGIES; ++i) {
            assertTrue(vault.withdrawalQueue(i) == newQueue[i]);
        }
    }

    /// @notice Test liquidating certain amount of assets from the vault.
    function testLiquidate() public {
        BaseStrategy newStrategy1 = new TestStrategy(AffineVault(address(vault)));
        token.mint(address(newStrategy1), 10);
        vault.addStrategy(newStrategy1, 10);
        BaseStrategy[] memory strategies = new BaseStrategy[](1);
        strategies[0] = newStrategy1;
        vm.warp(vault.lastHarvest() + vault.LOCK_INTERVAL() + 1);
        vault.harvest(strategies);
        vault.liquidate(10);
        assertTrue(token.balanceOf(address(vault)) == 10);
        assertTrue(newStrategy1.balanceOfAsset() == 0);
    }

    /// @notice Test internal rebalancing of vault.
    function testRebalance() public {
        BaseStrategy strat1 = new TestStrategy(AffineVault(address(vault)));
        BaseStrategy strat2 = new TestStrategy(AffineVault(address(vault)));

        vault.addStrategy(strat1, 6000);
        vault.addStrategy(strat2, 4000);

        // strat1 should have 6000 and strat2 should have 4000. Since we switch the numbers, calling `rebalance`
        // will move 2000 of `token` from strat2 to strat1
        token.mint(address(strat1), 4000);
        token.mint(address(strat2), 6000);

        // Harvest
        BaseStrategy[] memory strategies = new BaseStrategy[](2);
        strategies[0] = strat1;
        strategies[1] = strat2;
        vm.warp(vault.lastHarvest() + vault.LOCK_INTERVAL() + 1);
        vault.harvest(strategies);

        vault.rebalance();

        assertTrue(token.balanceOf(address(strat1)) == 6000);
        assertTrue(token.balanceOf(address(strat2)) == 4000);
    }

    /// @notice Test internal rebalanceing of vault when strategies incur slippage while divesting from them.
    function testRebalanceWithSlippage() public {
        // If we lose money when divesting from strategies, then we might have to
        // to send a truncated amount to one of the strategies in need of assets

        BaseStrategy strat1 = new TestStrategy(AffineVault(address(vault)));
        BaseStrategy strat2 = new TestStrategyDivestSlippage(AffineVault(address(vault)));

        vault.addStrategy(strat1, 6000);
        vault.addStrategy(strat2, 4000);

        // strat1 should have 6000 and strat2 should have 4000.
        // Since strat2.divest(2000) will only divest 1000, we'll end up with 5000 in each strategy
        token.mint(address(strat1), 4000);
        token.mint(address(strat2), 6000);

        // Harvest
        BaseStrategy[] memory strategies = new BaseStrategy[](2);
        strategies[0] = strat1;
        strategies[1] = strat2;
        vm.warp(vault.lastHarvest() + vault.LOCK_INTERVAL() + 1);
        vault.harvest(strategies);

        vault.rebalance();

        assertTrue(token.balanceOf(address(strat1)) == 5000);
        assertTrue(token.balanceOf(address(strat2)) == 5000);
    }

    /// @notice Test updating strategy allocation bps.
    function testUpdateStrategyAllocations() public {
        BaseStrategy strat1 = new TestStrategy(AffineVault(address(vault)));
        BaseStrategy strat2 = new TestStrategy(AffineVault(address(vault)));

        vault.addStrategy(strat1, 5000);
        vault.addStrategy(strat2, 5000);

        BaseStrategy[] memory strategyList = new BaseStrategy[](2);
        strategyList[0] = strat1;
        strategyList[1] = strat2;

        uint16[] memory bpsList = new uint16[](2);
        bpsList[0] = 100;
        bpsList[1] = 200;

        vault.updateStrategyAllocations(strategyList, bpsList);
        (, uint256 strat1TvlBps,) = vault.strategies(strat1);
        (, uint256 strat2TvlBps,) = vault.strategies(strat2);

        assertEq(strat1TvlBps, 100);
        assertEq(strat2TvlBps, 200);
    }
}

contract BaseVaultTest is CommonVaultTestSuite {
    function setUp() public {
        token = new MockERC20("Mock", "MT", 18);
        vault = new BaseVaultLiquidate();

        vault.baseInitializeMock(
            address(this), // governance
            token, // token
            address(0),
            BridgeEscrow(address(0))
        );
    }

    /// @notice Test updating bridge escrow contract. Only governance should be able to do it.
    function testBridgeEscrow() public {
        BridgeEscrow escrow = BridgeEscrow(makeAddr("worm_router"));
        vault.setBridgeEscrow(escrow);
        assertEq(address(vault.bridgeEscrow()), address(escrow));
        // only gov can call
        vm.prank(alice);
        vm.expectRevert("Only Governance.");
        vault.setBridgeEscrow(BridgeEscrow(address(0)));
    }

    /// @notice Test updating wormhole router. Only governance should be able to do it.
    function testSetWormRouter() public {
        address wormRouter = makeAddr("worm_router");
        vault.setWormholeRouter(wormRouter);
        assertEq(vault.wormholeRouter(), wormRouter);
        // only gov can call
        vm.prank(alice);
        vm.expectRevert("Only Governance.");
        vault.setWormholeRouter(address(0));
    }
}

contract AffineVaultTest is CommonVaultTestSuite {
    function setUp() public {
        token = new MockERC20("Mock", "MT", 18);
        AffineVaultLiquidate affineVault = new AffineVaultLiquidate();
        affineVault.initialize(
            address(this), // governance
            token // token
        );
        vault = BaseVaultLiquidate(address(affineVault));
    }
}
