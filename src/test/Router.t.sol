// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.16;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {TestPlus} from "./TestPlus.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

import {L2Vault} from "../polygon/L2Vault.sol";
import {TwoAssetBasket} from "../polygon/TwoAssetBasket.sol";
import {BaseStrategy} from "../BaseStrategy.sol";
import {Deploy} from "./Deploy.sol";
import {ERC4626Router} from "../polygon/ERC4626Router.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

contract RouterTest is TestPlus {
    using stdStorage for StdStorage;

    ERC20 token = ERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    L2Vault vault;
    ERC4626Router router;
    TwoAssetBasket basket;

    function setUp() public {
        vm.createSelectFork("polygon", 31_824_532);
        vault = Deploy.deployL2Vault();
        uint256 slot = stdstore.target(address(vault)).sig("asset()").find();
        bytes32 tokenAddr = bytes32(uint256(uint160(address(token))));
        vm.store(address(vault), bytes32(slot), tokenAddr);
        router = new ERC4626Router("");
        basket = Deploy.deployTwoAssetBasket(token);
    }

    function testMultipleDeposits() public {
        address user = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
        deal(address(token), user, 10e6);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(router.depositToVault.selector, IERC4626(address(basket)), user, 1e6, 0);
        data[1] = abi.encodeWithSelector(router.depositToVault.selector, IERC4626(address(vault)), user, 1e6, 0);
        vm.startPrank(user);
        token.approve(address(router), 2e6);
        router.approve(token, address(vault), 2e6);
        router.approve(token, address(basket), 2e6);
        router.multicall(data);
        assert(vault.balanceOf(user) > 0);
        assert(basket.balanceOf(user) > 0);
    }
}
