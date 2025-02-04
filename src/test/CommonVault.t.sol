// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

import {TestPlus} from "./TestPlus.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Vault, ERC721} from "src/vaults/Vault.sol";
import {VaultV2} from "src/vaults/VaultV2.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {BaseStrategy} from "src/strategies/BaseStrategy.sol";
import {BaseVault} from "src/vaults/cross-chain-vault/BaseVault.sol";
import {TestStrategy} from "./mocks/TestStrategy.sol";
import {VaultErrors} from "src/libs/VaultErrors.sol";

import {console2} from "forge-std/console2.sol";

contract MockNft is ERC721 {
    constructor(string memory _name, string memory _symbol) ERC721(_name, _symbol) {}

    function tokenURI(uint256 id) public view override returns (string memory) {
        return "fakeuri";
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice Test common vault functionalities.
contract CommonVaultTest is TestPlus {
    using stdStorage for StdStorage;

    VaultV2 vault;
    ERC20 asset;

    function setUp() public virtual {
        asset = new MockERC20("Mock", "MT", 6);

        vault = new VaultV2();
        vault.initialize(governance, address(asset), "USD Earn", "usdEarn");
    }

    function _getRemainingVaultTvlCap() internal virtual returns (uint256) {
        return type(uint104).max;
    }

    function _giveAssets(address user, uint256 assets) internal virtual {
        MockERC20(address(asset)).mint(user, assets);
    }

    function _getStrategy() internal virtual returns (BaseStrategy) {
        BaseStrategy strategy = new TestStrategy(vault);
        vm.prank(governance);
        vault.addStrategy(strategy, 0);
        return strategy;
    }

    function _harvest(BaseStrategy strat) internal virtual {
        vm.warp(vault.lastHarvest() + vault.LOCK_INTERVAL() + 1);

        BaseStrategy[] memory strategyList = new BaseStrategy[](1);
        strategyList[0] = strat;
        vm.prank(governance);
        vault.harvest(strategyList);

        // unlock profit
        vm.warp(vault.lastHarvest() + vault.LOCK_INTERVAL() + 1);
    }

    event Upgraded(address indexed implementation);

    function testCanUpgrade() public {
        // Deploy vault
        Vault impl = new Vault();

        // Initialize proxy with correct data
        bytes memory initData = abi.encodeCall(Vault.initialize, (governance, address(asset), "name", "symbol"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        Vault _vault = Vault(address(proxy));

        Vault impl2 = new Vault();

        vm.expectRevert("Only Governance.");
        _vault.upgradeTo(address(impl2));

        vm.prank(governance);
        vm.expectEmit(true, false, false, false);
        emit Upgraded(address(impl2));
        _vault.upgradeTo(address(impl2));
    }

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Test redeeming after deposit.
    function testDepositRedeem(uint256 amountAsset) public {
        // uint256 amountAsset = 34726741556481429907439559283666110;
        vm.assume(amountAsset > 99 && amountAsset <= _getRemainingVaultTvlCap());
        // Running into overflow issues on the call to vault.redeem
        address user = address(this);
        _giveAssets(user, amountAsset);

        uint256 expectedShares = vault.previewDeposit(amountAsset);
        // user gives max approval to vault for asset
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(amountAsset, user);

        assertEq(vault.balanceOf(user), expectedShares);
        assertEq(asset.balanceOf(address(user)), 0);

        uint256 assetsReceived = vault.redeem(expectedShares, user, user);

        assertEq(vault.balanceOf(user), 0);
        assertApproxEqAbs(assetsReceived, amountAsset, 10); // We round down when sending assets out, so user may get slightly less
    }

    /// @notice Test withdawing after deposit.
    function testDepositWithdraw(uint64 amountAsset) public {
        vm.assume(amountAsset > 99 && amountAsset <= _getRemainingVaultTvlCap());
        // shares = assets * totalShares / totalAssets but totalShares will actually be bigger than a uint128
        // so the `assets * totalShares` calc will overflow if using a uint128
        address user = address(this);
        _giveAssets(user, amountAsset);
        asset.approve(address(vault), type(uint256).max);

        // If vault is empty, assets are converted to shares at 1:vault.initialSharesPerAsset() ratio
        uint256 expectedShares = vault.previewDeposit(amountAsset); // cast to uint256 to prevent overflow

        vm.expectEmit(true, true, true, true);
        emit Deposit(address(this), address(this), amountAsset, expectedShares);
        vault.deposit(amountAsset, user);

        assertEq(vault.balanceOf(user), expectedShares);
        assertEq(asset.balanceOf(user), 0);

        vault.redeem(expectedShares, user, user);
        assertEq(vault.balanceOf(user), 0);
        assertApproxEqAbs(asset.balanceOf(user), amountAsset, 10);
    }

    /// @notice Test minting vault token.
    function testMint(uint64 amountAsset) public {
        vm.assume(amountAsset > 99 && amountAsset <= _getRemainingVaultTvlCap());
        address user = address(this);
        _giveAssets(user, amountAsset);
        asset.approve(address(vault), type(uint256).max);

        // If vault is empty, assets are converted to shares at 1:vault.initialSharesPerAsset() ratio
        uint256 expectedShares = vault.previewDeposit(amountAsset); // cast to uint256 to prevent overflow

        vm.expectEmit(true, true, true, true);
        emit Deposit(address(this), address(this), amountAsset, expectedShares);
        vault.mint(expectedShares, user);

        assertEq(vault.balanceOf(user), expectedShares);
    }

    /// @notice Test minting zero share results in error.
    function testMinDeposit() public {
        address user = address(this);
        _giveAssets(user, 100);
        asset.approve(address(vault), type(uint256).max);

        // If we're minting zero shares we revert
        vm.expectRevert(VaultErrors.ZeroShares.selector);
        vault.deposit(0, user);

        vault.deposit(100, user);
    }

    /// @notice Test that withdrawal fee is deducted while withdwaring.
    function testWithdrawalFee() public {
        vm.prank(governance);
        vault.setWithdrawalFee(50);

        uint256 amountAsset = Math.min(1e18, _getRemainingVaultTvlCap());

        vm.startPrank(alice);
        _giveAssets(alice, amountAsset);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(amountAsset, alice);

        uint256 govBalBefore = asset.balanceOf(vault.governance());
        vault.redeem(vault.balanceOf(alice), alice, alice);
        assertEq(vault.balanceOf(alice), 0);

        // User gets the original amount with 50bps deducted
        assertApproxEqAbs(asset.balanceOf(alice), (amountAsset * (10_000 - 50)) / 10_000, 10);
        // Governance gets the 50bps fee
        assertApproxEqAbs(asset.balanceOf(vault.governance()) - govBalBefore, (amountAsset * 50) / 10_000, 10);
    }

    /// @notice Test that goveranance can modify management fees.
    function testCanSetManagementAndWithdrawalFees() public {
        vm.startPrank(governance);
        vault.setManagementFee(300);
        assertEq(vault.managementFee(), 300);
        vault.setWithdrawalFee(10);
        assertEq(vault.withdrawalFee(), 10);

        vm.startPrank(alice);
        vm.expectRevert("Only Governance.");
        vault.setManagementFee(300);
        vm.expectRevert("Only Governance.");
        vault.setWithdrawalFee(10);
    }

    /// @notice Test that goveranance can pause the vault.
    function testVaultPause() public {
        vm.startPrank(governance);
        vault.pause();

        vm.expectRevert("Pausable: paused");
        vault.deposit(1e18, address(this));

        vm.expectRevert("Pausable: paused");
        vault.withdraw(1e18, address(this), address(this));
        vault.unpause();

        vm.stopPrank();

        // can deposit and withdraw over tvl cap

        testDepositWithdraw(uint64(Math.min(1e18, _getRemainingVaultTvlCap())));

        // Only those with GUARDIAN_ROLE address can call pause or unpause
        string memory errString = string(
            abi.encodePacked(
                "AccessControl: account ",
                Strings.toHexString(uint160(alice), 20),
                " is missing role ",
                Strings.toHexString(uint256(vault.GUARDIAN_ROLE()), 32)
            )
        );

        bytes memory errorMsg = abi.encodePacked(errString);

        vm.expectRevert(errorMsg);
        vm.startPrank(alice);
        vault.pause();

        vm.expectRevert(errorMsg);
        vault.unpause();
    }

    /// @notice Test that view functions for detailed price of vault token works.
    function testDetailedPrice() public {
        Vault.Number memory price = vault.detailedPrice();

        _giveAssets(address(vault), 2e18);

        // If we increase tvl the price increases
        Vault.Number memory price2 = vault.detailedPrice();
        assertTrue(price2.num > price.num);
        // Price is exactly one share's worth of assets
        assertEq(price2.num, vault.convertToAssets(10 ** vault.decimals()));
    }

    /// @notice If needNftToDeposit is set, you need an nft to deposit
    function testNft() public {
        _giveAssets(address(this), 1e18);
        asset.approve(address(vault), type(uint256).max);

        MockNft nft = new MockNft("foo", "bar");
        vm.startPrank(governance);
        vault.setAccessNft(nft);
        vault.setNftProperties(true, false);
        vm.stopPrank();

        vm.expectRevert("Caller has no access NFT");
        vault.deposit(1e18, address(this));

        nft.mint(address(this), 1);
        vault.deposit(1e18, address(this));
    }

    /// @notice If nft address is set and you have it you pay a reduced fee.
    function testWithdrawalFeeWithNft() public {
        // Alice deposits
        uint256 amountAsset = 10 ** uint256(asset.decimals());
        vm.startPrank(alice);
        _giveAssets(alice, amountAsset);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(amountAsset, alice);
        vm.stopPrank();

        MockNft nft = new MockNft("foo", "bar");
        nft.mint(bob, 1);

        // Fees set
        vm.startPrank(governance);
        vault.setWithdrawalFee(50);
        vault.setWithdrawalFeeWithNft(10);
        vault.setAccessNft(nft);
        vault.setNftProperties(false, true);
        vm.stopPrank();

        // Bob has nft and gets discount
        vm.startPrank(bob);
        _giveAssets(bob, amountAsset);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(amountAsset, bob);

        vault.redeem(vault.balanceOf(bob), bob, bob);
        assertEq(vault.balanceOf(bob), 0);

        // Bob gets 10 bps fee -> Allowin some leeway for rounding errors
        assertApproxEqAbs(asset.balanceOf(bob), (amountAsset * (10_000 - 10)) / 10_000, 2);

        // Alice gets 50 bps fee
        vm.startPrank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);
        assertEq(vault.balanceOf(alice), 0);
        assertApproxEqAbs(asset.balanceOf(alice), (amountAsset * (10_000 - 50)) / 10_000, 2);
    }

    function testPerformanceFee() public {
        // Unlock any profits
        vm.warp(block.timestamp + 24 hours);

        // get a strategy
        BaseStrategy strat = _getStrategy();

        vm.prank(governance);
        vault.setPerformanceFeeBps(1000); // 10%
        uint256 oldPerfFee = uint256(vault.accumulatedPerformanceFee());

        // Give money to strategy
        uint256 oldTvl = vault.totalAssets();
        uint256 assetsGained = oldTvl > 0 ? oldTvl : 100 * 10 ** (asset.decimals());
        _giveAssets(address(strat), assetsGained);

        // We got the correct performance fee
        // Call harvest
        _harvest(strat);

        // Price went up by the correct amount
        uint256 perfFee = assetsGained / 10;
        // Beefy Strategy might increase increase in tvl a bit after warping forward
        assertApproxEqRel(vault.totalAssets(), oldTvl + assetsGained - perfFee, 0.005e18);

        // Performance fee increased
        assertApproxEqRel(uint256(vault.accumulatedPerformanceFee()), oldPerfFee + perfFee, 0.005e18);

        uint256 oldGovBal = asset.balanceOf(vault.governance());
        oldPerfFee = vault.accumulatedPerformanceFee();

        console2.log("old: %s, %s", oldGovBal, oldPerfFee);

        vm.prank(vault.governance());
        vault.withdrawPerformanceFee();

        uint256 newGovBal = asset.balanceOf(vault.governance());
        uint256 newPerfFee = vault.accumulatedPerformanceFee();
        console2.log("new: %s, %s", newGovBal, newPerfFee);
        assertTrue(newGovBal > oldGovBal && newPerfFee < oldPerfFee);
        assertEq(oldGovBal + oldPerfFee - newPerfFee, newGovBal);
    }
}
