// SPDX-License-Identifier:MIT
pragma solidity ^0.8.10;
import { L2Vault } from "./L2Vault.sol";
import { BaseRelayRecipient } from "@opengsn/contracts/src/BaseRelayRecipient.sol";

contract Relayer is BaseRelayRecipient {
    L2Vault vault;

    constructor(address _forwarder, address _vault) {
        _setTrustedForwarder(_forwarder);
        vault = L2Vault(_vault);
    }

    // NOTE: Only using `this` because I can't mock _msgSender as an internal call (JUMP)
    // See https://github.com/gakonst/foundry/issues/432
    function deposit(uint256 amountToken) external {
        vault.depositGasLess(_msgSender(), amountToken);
    }

    function withdraw(uint256 shares) external {
        vault.withdrawGasLess(_msgSender(), shares);
    }

    function versionRecipient() external pure override returns (string memory) {
        return "1";
    }
}
