// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IIdo {
    function initialize(
        address _creator,
        address _rewardToken,
        address _targetToken,
        uint256[] memory _idolsit,
        address[] memory _actingaddre,
        uint256[] memory _addrerate
    ) external;

    function setCreator(address _creator) external;

    // function setParentRates(uint _parentRate,uint _grandpaRate) external;

    // function takeToken(address token,address to,uint256 amount) external;

    // function takeETH(address to,uint256 amount) external;
}