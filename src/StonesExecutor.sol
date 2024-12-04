// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface StonesInterface {
    function roll(uint256 round) external;

    function executeResult(
        uint256 round,
        uint256 offset,
        uint256 limit
    ) external;

    function settleLostBets(
        uint256 round,
        uint256 offset,
        uint256 limit
    ) external;

    function getBetsCount(uint round) external view returns (uint256);

    function getCurrentRound() external view returns (uint256);

    function getRoundBetsCount(uint round) external view returns (uint256);
}

contract StonesExecutor {
    function execute(address stones) external {
        StonesInterface(stones).roll(
            StonesInterface(stones).getCurrentRound() - 1
        );
    }

    function distribute(address stones) external {
        uint256 round = StonesInterface(stones).getCurrentRound() - 1;
        StonesInterface(stones).executeResult(
            round,
            0,
            StonesInterface(stones).getRoundBetsCount(round)
        );
    }
}
