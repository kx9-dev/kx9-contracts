// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KX9Shield, IKX9PriceOracle, IERC20} from "./KX9Shield.sol";

/// @title KX9ShieldFactory
/// @notice Commissions KX-9 units. Each call deploys one Shield vault owned by the caller.
contract KX9ShieldFactory {
    IKX9PriceOracle public immutable oracle;
    IERC20 public immutable accessToken;
    uint256 public immutable autonomousMinBalance;
    address public immutable defaultExecutor;

    address public admin;
    address[] public defaultRouters;
    uint256 public unitCount;

    mapping(uint256 => address) public shieldOf;      // agentId => shield
    mapping(address => uint256[]) internal _unitsOf;  // operator => agentIds

    event UnitCommissioned(uint256 indexed agentId, address indexed operator, address shield, string serial);
    event DefaultRoutersUpdated(address[] routers);

    error NotAdmin();

    constructor(
        IKX9PriceOracle oracle_,
        IERC20 accessToken_,
        uint256 autonomousMinBalance_,
        address defaultExecutor_,
        address[] memory routers_
    ) {
        oracle = oracle_;
        accessToken = accessToken_;
        autonomousMinBalance = autonomousMinBalance_;
        defaultExecutor = defaultExecutor_;
        defaultRouters = routers_;
        admin = msg.sender;
    }

    function setDefaultRouters(address[] calldata routers_) external {
        if (msg.sender != admin) revert NotAdmin();
        defaultRouters = routers_;
        emit DefaultRoutersUpdated(routers_);
    }

    function setAdmin(address a) external {
        if (msg.sender != admin) revert NotAdmin();
        admin = a;
    }

    function unitsOf(address operator) external view returns (uint256[] memory) { return _unitsOf[operator]; }

    function routers() external view returns (address[] memory) { return defaultRouters; }

    /// @notice Deploy a new unit for msg.sender with starting limits and whitelist.
    function commission(KX9Shield.Limits calldata limits, address[] calldata whitelist)
        external
        returns (uint256 agentId, address shield)
    {
        agentId = ++unitCount;
        shield = address(
            new KX9Shield(agentId, msg.sender, defaultExecutor, oracle, accessToken, autonomousMinBalance,
                limits, whitelist, defaultRouters)
        );
        shieldOf[agentId] = shield;
        _unitsOf[msg.sender].push(agentId);
        emit UnitCommissioned(agentId, msg.sender, shield, _serial(agentId));
    }

    function _serial(uint256 id) internal pure returns (string memory) {
        bytes memory digits = bytes(_toString(id));
        bytes memory pad = new bytes(digits.length >= 4 ? 0 : 4 - digits.length);
        for (uint256 i; i < pad.length; ++i) pad[i] = "0";
        return string(abi.encodePacked("KX-9-", pad, digits));
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) ++len;
        bytes memory b = new bytes(len);
        while (v != 0) { b[--len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}
