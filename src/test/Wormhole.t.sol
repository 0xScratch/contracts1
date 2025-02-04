// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.16;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {TestPlus} from "./TestPlus.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Deploy} from "./Deploy.sol";

import {L2Vault} from "src/vaults/cross-chain-vault/L2Vault.sol";
import {L1Vault} from "src/vaults/cross-chain-vault/L1Vault.sol";
import {IWormhole} from "src/interfaces/IWormhole.sol";
import {L1WormholeRouter} from "src/vaults/cross-chain-vault/wormhole/L1WormholeRouter.sol";
import {L2WormholeRouter} from "src/vaults/cross-chain-vault/wormhole/L2WormholeRouter.sol";
import {WormholeRouter} from "src/vaults/cross-chain-vault/wormhole/WormholeRouter.sol";
import {Constants} from "src/libs/Constants.sol";

// This contract exists solely to test the internal view
contract MockRouter is L2WormholeRouter {
    constructor(L2Vault _vault, IWormhole _wormhole) L2WormholeRouter(_vault, _wormhole) {}

    function validateWormholeMessageEmitter(IWormhole.VM memory vm) public view {
        return _validateWormholeMessageEmitter(vm);
    }
}

/// @notice Test L2 wormhole router functinoalities.
contract L2WormholeRouterTest is TestPlus {
    using stdStorage for StdStorage;

    L2WormholeRouter router;
    L2Vault vault;
    address rebalancer = makeAddr("randomAddr");

    IWormhole wormhole;
    uint16 emitterChainId = uint16(2);

    function setUp() public {
        forkPolygon();
        vault = Deploy.deployL2Vault();
        router = L2WormholeRouter(vault.wormholeRouter());
        wormhole = router.wormhole();
    }

    /// @notice Test that the governance can update wormhole router configurations.
    function testWormholeConfigUpdates() public {
        // update consistencyLevel
        vm.startPrank(router.governance());
        router.setConsistencyLevel(100);
        assertEq(router.consistencyLevel(), 100);

        vm.startPrank(alice);
        vm.expectRevert("Only Governance.");
        router.setConsistencyLevel(0);
    }

    /// @notice Test that the L2 wormhole router sends message to L1 after funds are transferred to L2.
    function testTransferReport() public {
        // Only invariant is that the vault is the only caller
        vm.prank(alice);
        vm.expectRevert("WR: Only vault");
        router.reportFundTransfer(0);

        uint256 transferAmount = 100;
        bytes memory payload = abi.encode(Constants.L2_FUND_TRANSFER_REPORT, transferAmount);
        vm.expectCall(
            address(router.wormhole()),
            abi.encodeCall(IWormhole.publishMessage, (uint32(0), payload, router.consistencyLevel()))
        );

        vm.prank(address(vault));
        router.reportFundTransfer(transferAmount);

        // Turn on a fee (wormhole reverts if you send a msg.value != wormhole.messageFee)
        uint256 fee = 1 ether;
        stdstore.target(address(wormhole)).sig("messageFee()").checked_write(fee);

        // We can send ether/matic
        vm.expectCall(
            address(router.wormhole()),
            fee,
            abi.encodeCall(IWormhole.publishMessage, (uint32(1), payload, router.consistencyLevel()))
        );
        hoax(address(vault), fee);
        router.reportFundTransfer{value: fee}(transferAmount);
    }

    /// @notice Test that the message vailidation works.
    function testMessageValidation() public {
        MockRouter mockRouter = new MockRouter(vault, wormhole);
        uint16 emitter = uint16(2);

        IWormhole.VM memory vaa;
        vaa.emitterChainId = emitter;
        vaa.emitterAddress = bytes32(uint256(uint160(address(router))));
        vm.expectRevert("WR: bad emitter address");
        mockRouter.validateWormholeMessageEmitter(vaa);

        IWormhole.VM memory vaa1;
        vaa1.emitterChainId = uint16(0);
        vaa1.emitterAddress = bytes32(uint256(uint160(address(mockRouter))));
        vm.expectRevert("WR: bad emitter chain");
        mockRouter.validateWormholeMessageEmitter(vaa1);

        // This will work
        IWormhole.VM memory goodVaa;
        goodVaa.emitterChainId = emitter;
        goodVaa.emitterAddress = bytes32(uint256(uint160(address(mockRouter))));
        mockRouter.validateWormholeMessageEmitter(goodVaa);
    }

    /// @notice Test that, the L2 wormhole router requests funds from L1 in correct message format.
    function testRequestFunds() public {
        // Only invariant is that the vault is the only caller
        vm.prank(alice);
        vm.expectRevert("WR: Only vault");
        router.requestFunds(0);

        uint256 requestAmount = 100;
        bytes memory payload = abi.encode(Constants.L2_FUND_REQUEST, requestAmount);
        vm.expectCall(
            address(router.wormhole()),
            abi.encodeCall(IWormhole.publishMessage, (uint32(0), payload, router.consistencyLevel()))
        );

        vm.prank(address(vault));
        router.requestFunds(requestAmount);

        // Turn on a fee (wormhole reverts if you send a msg.value != wormhole.messageFee)
        uint256 fee = 1 ether;
        stdstore.target(address(wormhole)).sig("messageFee()").checked_write(fee);

        // We can send ether/matic
        vm.expectCall(
            address(router.wormhole()),
            fee,
            abi.encodeCall(IWormhole.publishMessage, (uint32(1), payload, router.consistencyLevel()))
        );
        hoax(address(vault), fee);
        router.requestFunds{value: fee}(requestAmount);
    }

    /// @notice Test that, the L2 wormhole router can receive funds sent by L1 vault.
    function testReceiveFunds() public {
        uint256 l1TransferAmount = 500;

        // Mock call to wormhole.parseAndVerifyVM()
        IWormhole.VM memory vaa;
        vaa.nonce = 20;
        vaa.payload = abi.encode(Constants.L1_FUND_TRANSFER_REPORT, l1TransferAmount);
        vaa.emitterAddress = bytes32(uint256(uint160(address(router))));
        vaa.emitterChainId = emitterChainId;

        bool valid = true;
        string memory reason = "";

        bytes memory wormholeReturnData = abi.encode(vaa, valid, reason);

        vm.mockCall(
            address(router.wormhole()),
            abi.encodeCall(IWormhole.parseAndVerifyVM, ("VAA_FROM_L1_TRANSFER")),
            wormholeReturnData
        );

        // Make sure that bridgEscrow has funds to send to the vault
        deal(vault.asset(), address(vault.bridgeEscrow()), l1TransferAmount);

        // Make sure that l1TotalLockedValue is above amount being transferred to L2 (or else we get an underflow)
        vm.store(
            address(vault),
            bytes32(stdstore.target(address(vault)).sig("l1TotalLockedValue()").find()),
            bytes32(uint256(l1TransferAmount))
        );

        // You need the rebalancer role in the vault in order to call this function
        // Governance gets the rebalancer role
        vm.prank(governance);
        router.receiveFunds("VAA_FROM_L1_TRANSFER");

        // Nonce is updated
        assertEq(router.nextValidNonce(), vaa.nonce + 1);

        // Assert that funds get cleared
        assertEq(ERC20(vault.asset()).balanceOf(address(vault)), l1TransferAmount);
    }

    /// @notice Test that old messages are not received by the wormhole router.
    function testReceiveFundsInvariants() public {
        // If wormhole says the vaa is bad, we revert
        // Mock call to wormhole.parseAndVerifyVM()
        IWormhole.VM memory vaa;
        vaa.emitterAddress = bytes32(uint256(uint160(address(router))));
        vaa.emitterChainId = emitterChainId;
        bool valid = false;
        string memory reason = "Reason string from wormhole contract";

        vm.mockCall(
            address(router.wormhole()),
            abi.encodeCall(IWormhole.parseAndVerifyVM, ("VAA_FROM_L1_TRANSFER")),
            abi.encode(vaa, valid, reason)
        );

        vm.startPrank(rebalancer);
        vm.expectRevert(bytes(reason));
        router.receiveFunds("VAA_FROM_L1_TRANSFER");
        vm.clearMockedCalls();

        // If the nonce is old, we revert
        IWormhole.VM memory vaa2;
        vaa2.nonce = 10;
        vaa2.emitterAddress = bytes32(uint256(uint160(address(router))));
        vaa2.emitterChainId = emitterChainId;

        // Make sure that l1TotalLockedValue is above amount being transferred to L2 (or else we get an underflow)
        vm.store(
            address(router),
            bytes32(stdstore.target(address(router)).sig("nextValidNonce()").find()),
            bytes32(uint256(11))
        );

        vm.mockCall(
            address(router.wormhole()),
            abi.encodeCall(IWormhole.parseAndVerifyVM, ("VAA_FROM_L1_TRANSFER")),
            abi.encode(vaa2, true, "")
        );

        vm.expectRevert("WR: old transaction");
        router.receiveFunds("VAA_FROM_L1_TRANSFER");
    }

    /// @notice Test that, the L2 wormhole router can receive TVL sent by L1 vault.
    function testReceiveTVL() public {
        // Mock call to to parseAndVerifyVM()
        uint256 tvl = 1000;
        bool received = true;

        IWormhole.VM memory vaa;
        vaa.payload = abi.encode(Constants.L1_TVL, tvl, received);
        vaa.emitterAddress = bytes32(uint256(uint160(address(router))));
        vaa.emitterChainId = emitterChainId;

        vm.mockCall(
            address(router.wormhole()),
            abi.encodeCall(IWormhole.parseAndVerifyVM, ("L1_TVL_VAA")),
            abi.encode(vaa, true, "")
        );

        vm.prank(rebalancer);
        vm.expectCall(address(vault), abi.encodeCall(vault.receiveTVL, (tvl, received)));
        router.receiveTVL("L1_TVL_VAA");

        assertEq(router.nextValidNonce(), 1);
    }
}

/// @notice Test L1 wormhole router functinoalities.
contract L1WormholeRouterTest is TestPlus {
    using stdStorage for StdStorage;

    L1WormholeRouter router;
    L1Vault vault;
    address rebalancer = makeAddr("randomAddr");
    IWormhole wormhole;
    uint16 emitterChainId = uint16(5);

    function setUp() public {
        forkEth();
        vault = Deploy.deployL1Vault();
        router = L1WormholeRouter(vault.wormholeRouter());
        wormhole = router.wormhole();
    }

    /// @notice Test router reports TVL to L2 in correct format.
    function testReportTVL() public {
        // Only invariant is that the vault is the only caller
        vm.prank(alice);
        vm.expectRevert("WR: only vault");
        router.reportTVL(0, false);

        uint256 tvl = 50_000;
        bool received = true;
        bytes memory payload = abi.encode(Constants.L1_TVL, tvl, received);
        vm.expectCall(
            address(router.wormhole()),
            abi.encodeCall(IWormhole.publishMessage, (uint32(0), payload, router.consistencyLevel()))
        );

        vm.prank(address(vault));
        router.reportTVL(tvl, received);

        uint256 fee = 1 ether;
        stdstore.target(address(wormhole)).sig("messageFee()").checked_write(fee);

        // We can send ether/matic
        vm.expectCall(
            address(router.wormhole()),
            fee,
            abi.encodeCall(IWormhole.publishMessage, (uint32(1), payload, router.consistencyLevel()))
        );
        hoax(address(vault), fee);
        router.reportTVL{value: fee}(tvl, received);
    }

    /// @notice Test that the wormhole router sends message after funds are transferred to L2.
    function testreportFundTransfer() public {
        // Only invariant is that the vault is the only caller
        vm.prank(alice);
        vm.expectRevert("WR: only vault");
        router.reportFundTransfer(0);

        uint256 requestAmount = 100;
        bytes memory payload = abi.encode(Constants.L1_FUND_TRANSFER_REPORT, requestAmount);
        vm.expectCall(
            address(router.wormhole()),
            abi.encodeCall(IWormhole.publishMessage, (uint32(0), payload, router.consistencyLevel()))
        );

        vm.prank(address(vault));
        router.reportFundTransfer(requestAmount);

        uint256 fee = 1 ether;
        stdstore.target(address(wormhole)).sig("messageFee()").checked_write(fee);

        // We can send ether/matic
        vm.expectCall(
            address(router.wormhole()),
            fee,
            abi.encodeCall(IWormhole.publishMessage, (uint32(1), payload, router.consistencyLevel()))
        );
        hoax(address(vault), fee);
        router.reportFundTransfer{value: fee}(requestAmount);
    }

    /// @notice Test receiving funds from L2 works.
    function testReceiveFunds() public {
        uint256 l2TransferAmount = 500;

        // Mock call to wormhole.parseAndVerifyVM()
        IWormhole.VM memory vaa;
        vaa.nonce = 2;
        vaa.payload = abi.encode(Constants.L2_FUND_TRANSFER_REPORT, l2TransferAmount);
        vaa.emitterAddress = bytes32(uint256(uint160(address(router))));
        vaa.emitterChainId = emitterChainId;

        bytes memory fakeVAA = bytes("VAA_FROM_L2_TRANSFER");
        vm.mockCall(
            address(router.wormhole()), abi.encodeCall(IWormhole.parseAndVerifyVM, (fakeVAA)), abi.encode(vaa, true, "")
        );

        // We use an empty exitProof since we are just going to mock the call to the bridgeEscrow
        bytes memory clearFundData = abi.encodeCall(vault.bridgeEscrow().clearFunds, (l2TransferAmount, ""));
        vm.mockCall(address(vault.bridgeEscrow()), clearFundData, "");
        vm.expectCall(address(vault.bridgeEscrow()), clearFundData);
        vm.prank(rebalancer);
        router.receiveFunds(fakeVAA, "");

        // Nonce is updated
        assertEq(router.nextValidNonce(), vaa.nonce + 1);
    }

    /// @notice Test receiving fund request from L2.
    function testReceiveFundRequest() public {
        // Mock call to wormhole.parseAndVerifyVM()
        uint256 requestAmount = 200;
        IWormhole.VM memory vaa;
        vaa.payload = abi.encode(Constants.L2_FUND_REQUEST, requestAmount);
        vaa.emitterAddress = bytes32(uint256(uint160(address(router))));
        vaa.emitterChainId = emitterChainId;

        bytes memory fakeVAA = bytes("L2_FUND_REQ");
        vm.mockCall(
            address(router.wormhole()), abi.encodeCall(IWormhole.parseAndVerifyVM, (fakeVAA)), abi.encode(vaa, true, "")
        );

        // We call processFundRequest
        // We mock the call to the above function since it is tested separately
        bytes memory processData = abi.encodeCall(vault.processFundRequest, (requestAmount));
        vm.mockCall(address(vault), processData, "");
        vm.expectCall(address(vault), processData);
        vm.prank(rebalancer);
        router.receiveFundRequest(fakeVAA);
    }
}
