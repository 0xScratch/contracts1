// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.16;

import {MinimalForwarder} from "@openzeppelin/contracts/metatx/MinimalForwarder.sol";
import {uncheckedInc} from "src/libs/Unchecked.sol";

contract Forwarder is MinimalForwarder {
    function executeBatch(ForwardRequest[] calldata requests, bytes calldata signatures) external payable {
        // get 65 byte chunks, each chunk is a signature
        uint256 start = 0;
        uint256 end = 65;

        for (uint256 i = 0; i < requests.length; i = uncheckedInc(i)) {
            ForwardRequest calldata req = requests[i];
            bytes calldata sig = signatures[start:end];
            start += 65;
            end += 65;
            (bool success,) = execute(req, sig);
            require(success, "Fwd: call failed");
        }
    }
}
