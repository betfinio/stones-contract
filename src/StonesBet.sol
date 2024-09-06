// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin/access/Ownable.sol";
import "./shared/BetInterface.sol";

/**
Errors in this contract
* STB01 - invalid contrstuctor params
*/

contract StonesBet is Ownable, BetInterface {
    address private immutable player;
    address private immutable game;
    uint256 private immutable totalAmount;
    uint256 private immutable created;
    // 0 - do not exists
    // 1 - registered
    // 2 - win
    // 3 - lose
    uint256 private status;
    uint256 private result;
    uint256 private immutable side;

    event StatusChanged(uint256 indexed status);
    event ResultChanged(uint256 indexed result);

    constructor(
        address _player,
        address _game,
        uint256 _amount,
        uint256 _side
    ) {
        require(_player != address(0), "STB01");
        require(_game != address(0), "STB02");
        created = block.timestamp;
        player = _player;
        game = _game;
        totalAmount = _amount;
        status = 1;
        side = _side;
    }

    function getPlayer() external view override returns (address) {
        return player;
    }

    function getGame() external view override returns (address) {
        return game;
    }

    function getAmount() external view override returns (uint256) {
        return totalAmount;
    }

    function getStatus() external view override returns (uint256) {
        return status;
    }

    function getCreated() external view override returns (uint256) {
        return created;
    }

    function getResult() external view returns (uint256) {
        return result;
    }

    function getSide() external view returns (uint256) {
        return side;
    }

    function getBetInfo()
        external
        view
        override
        returns (address, address, uint256, uint256, uint256, uint256)
    {
        return (player, game, totalAmount, result, status, created);
    }

    function setStatus(uint256 _status) public onlyOwner {
        status = _status;
        emit StatusChanged(status);
    }

    function setResult(uint256 _result) public onlyOwner {
        result = _result;
        emit ResultChanged(result);
    }
}
