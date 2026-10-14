// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Callback interface used by `HookERC20` (modelled on ERC-777 `tokensToSend` /
///         `tokensReceived`).
interface IHookReceiver {
    function onTokenHook(address token, address from, address to, uint256 amount) external;
}

/// @title HookERC20
/// @notice A deliberately HOSTILE token for reentrancy tests: when hooks are on, every transfer
///         first notifies the sender (like `tokensToSend`, before balances move) and afterwards
///         the recipient (like `tokensReceived`). Contracts that do not implement the hook (e.g.
///         the market itself) are skipped via try/catch.
///         NEVER deploy as a real asset: open mint, and a transfer hook that can run arbitrary code.
contract HookERC20 is ERC20 {
    uint8 private immutable _DECIMALS;
    bool public hooksOn;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHooks(bool on) external {
        hooksOn = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        bool hook = hooksOn && from != address(0) && to != address(0);
        if (hook && from.code.length > 0) {
            // "tokensToSend": runs BEFORE the balances change.
            try IHookReceiver(from).onTokenHook(address(this), from, to, value) {} catch {}
        }
        super._update(from, to, value);
        if (hook && to.code.length > 0) {
            // "tokensReceived": runs AFTER the balances changed.
            try IHookReceiver(to).onTokenHook(address(this), from, to, value) {} catch {}
        }
    }
}
