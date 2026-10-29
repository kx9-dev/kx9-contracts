// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockERC20 {
    string public name; string public symbol; uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// 1 whole token = priceUsd6 USD (6 decimals); tokens use 18 decimals except USDC (6).
contract MockOracle {
    mapping(address => uint256) public price; mapping(address => uint8) public dec;
    function set(address t, uint256 p, uint8 d) external { price[t] = p; dec[t] = d; }
    function usdValue(address t, uint256 a) external view returns (uint256) {
        require(price[t] != 0, "no price");
        return a * price[t] / (10 ** dec[t]);
    }
}

/// Swaps tokenIn for tokenOut at a fixed rate (out per 1e18 in), with optional haircut in bps.
contract MockRouter {
    uint256 public haircutBps;
    function setHaircut(uint256 b) external { haircutBps = b; }
    function swap(address tin, address tout, uint256 amountIn, uint256 rate1e18, address to) external {
        MockERC20(tin).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * rate1e18 / 1e18;
        out = out * (10_000 - haircutBps) / 10_000;
        MockERC20(tout).mint(to, out);
    }
}
