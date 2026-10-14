// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DiffHarness} from "./DiffHarness.sol";

/// @notice Checks the Solidity against `vectors.txt`: a fixed, edge-heavy list of
///         (function, arguments) -> (outputs | FAIL) produced by an INDEPENDENT implementation of
///         docs/DESIGN.md section 9.
///
///         The same file is meant to be loaded by the C++ reference model's own unit tests, so it
///         pins the shared contract from both sides. It needs no ffi and runs in the default
///         profile. When this test fails, either the spec text, the vector generator or the
///         Solidity is wrong, which is exactly what must be understood before M8.
///
///         Line format:   name(types) arg1 arg2 ... => out1 out2 ...    or    => FAIL
contract VectorsTest is Test {
    string internal constant FILE = "test/differential/vectors.txt";

    DiffHarness internal h;

    function setUp() public {
        h = new DiffHarness();
    }

    function test_vectors_solidityMatchesIndependentModel() public {
        string[] memory lines = vm.split(vm.readFile(FILE), "\n");
        uint256 checked;
        uint256 failures;

        for (uint256 i = 0; i < lines.length; i++) {
            string memory line = lines[i];
            if (bytes(line).length == 0 || bytes(line)[0] == "#") continue;

            string[] memory tok = vm.split(line, " ");
            // locate the "=>" separator
            uint256 sep = tok.length;
            for (uint256 j = 0; j < tok.length; j++) {
                if (keccak256(bytes(tok[j])) == keccak256("=>")) {
                    sep = j;
                    break;
                }
            }
            require(sep > 0 && sep < tok.length, "vectors.txt: malformed line");

            // calldata = selector(signature) ++ one 32-byte word per argument
            bytes memory data = abi.encodePacked(bytes4(keccak256(bytes(tok[0]))));
            for (uint256 j = 1; j < sep; j++) {
                data = bytes.concat(data, abi.encode(vm.parseUint(tok[j])));
            }

            (bool ok, bytes memory ret) = address(h).call(data);
            bool expectFail = keccak256(bytes(tok[sep + 1])) == keccak256("FAIL");

            bool good;
            if (expectFail) {
                good = !ok;
            } else {
                good = ok && ret.length == 32 * (tok.length - sep - 1);
                for (uint256 k = 0; good && k < tok.length - sep - 1; k++) {
                    uint256 word;
                    assembly {
                        word := mload(add(ret, add(32, mul(k, 32))))
                    }
                    good = word == vm.parseUint(tok[sep + 1 + k]);
                }
            }

            checked++;
            if (!good) {
                failures++;
                if (failures <= 10) {
                    console.log(
                        string.concat("VECTOR MISMATCH line ", vm.toString(i + 1), ": ", line)
                    );
                }
            }
        }

        console.log("vectors checked:", checked);
        assertGt(checked, 1000, "vectors.txt unexpectedly small");
        assertEq(failures, 0, "Solidity disagrees with the independent model (see logs)");
    }
}
