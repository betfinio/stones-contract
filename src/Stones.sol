// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./shared/staking/StakingInterface.sol";
import "./StonesBet.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "./shared/games/GameInterface.sol";
import "./shared/CoreInterface.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "chainlink/vrf/dev/VRFCoordinatorV2_5.sol";
import "chainlink/vrf/dev/VRFConsumerBaseV2Plus.sol";

/**
 * Error codes used in this contract:
 * ST00 - invallid caller
 * ST01 - invalid input data
 * ST02 - invalid round
 * ST03 - round not finished
 * ST04 - round has no bets
 * ST05 - transfer failed
 * ST06 - invalid constructor params
 * ST07 - invalid balance
 * ST09 - unkonwn request
 */

contract Stones is VRFConsumerBaseV2Plus, GameInterface, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error RoundNotFinished(uint256 round);

    uint256 private immutable created;
    uint256 private immutable subscriptionId;
    address public immutable vrfCoordinator;
    bytes32 public immutable keyHash;
    uint16 public constant requestConfirmations = 3;
    address private immutable token;
    uint256 private constant bonusPart = 5_00;

    uint256 private constant interval = 10 minutes;

    StakingInterface public immutable staking;
    CoreInterface public immutable core;

    mapping(uint256 => StonesBet[]) public roundBets;
    mapping(address => bool) public betSettled;
    mapping(uint256 => uint256) public distributedInRound;
    mapping(uint256 => mapping(uint256 => StonesBet[])) public roundBetsBySide;
    mapping(uint256 => mapping(uint256 => uint256)) public roundBankBySide;
    mapping(uint256 => mapping(uint256 => uint256)) public roundProbabilities;
    mapping(uint256 => mapping(uint256 => uint256))
        public roundBonusSharesBySide;

    mapping(uint256 => uint256) public roundWinnerSide;
    // 0 - not started
    // 1 - spinning
    // 2 - finished
    mapping(uint256 => uint256) public roundStatus;
    mapping(uint256 => uint256) public roundRequests;
    mapping(uint256 => uint256) public requestRounds;

    event RoundStart(uint256 indexed round, uint256 indexed timestamp);
    event BetCreated(address indexed bet, uint256 indexed round);
    event RequestedCalculation(
        uint256 indexed round,
        uint256 indexed requestId,
        uint256 indexed timestamp
    );
    event WinnerCalculated(uint256 indexed round, uint256 indexed side);

    constructor(
        uint256 _subscriptionId,
        address _core,
        address _staking,
        address _vrfCoordinator,
        bytes32 _keyHash,
        address _admin
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        require(_core != address(0), "ST06");
        require(_staking != address(0), "ST06");
        require(_admin != address(0), "ST06");
        require(_subscriptionId > 0, "ST06");
        // validation for vrf coordinator is not needed because it is already validated in the VRFConsumerBaseV2Plus contract
        vrfCoordinator = _vrfCoordinator;
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        core = CoreInterface(_core);
        require(core.isStaking(_staking), "ST06");
        staking = StakingInterface(_staking);
        created = block.timestamp;
        token = staking.getToken();
    }

    function placeBet(
        address _player,
        uint256 _totalAmount,
        bytes calldata _data
    ) external returns (address betAddress) {
        require(address(core) == msg.sender, "ST00");
        (uint256 _value, uint256 _side, uint256 _round) = abi.decode(
            _data,
            (uint256, uint256, uint256)
        );
        // check input data
        // require(_totalAmount > 0, "ST01"); // not needed because it is checked in the Partner contract
        require(_totalAmount == _value * 1 ether, "ST01");
        require(_side >= 1 && _side <= 5, "ST01");
        require(_round == getCurrentRound(), "ST02");
        // create bet
        StonesBet bet = new StonesBet(
            _player,
            address(this),
            _totalAmount,
            _side,
            roundBetsBySide[_round][_side].length + 1
        );
        // add bet to round
        roundBets[_round].push(bet);
        // add bet to side
        roundBetsBySide[_round][_side].push(bet);
        // increase bank
        roundBankBySide[_round][0] += _totalAmount;
        // increase side bank
        roundBankBySide[_round][_side] += _totalAmount;
        // increase total probability
        roundProbabilities[_round][0] += _value;
        // increase side probability
        roundProbabilities[_round][_side] += _value;
        // increate bonus share
        roundBonusSharesBySide[_round][_side] += roundBankBySide[_round][_side];
        // emit event if round started
        if (getRoundBetsCount(_round) == 1) {
            emit RoundStart(_round, block.timestamp);
        }
        emit BetCreated(address(bet), _round);
        return address(bet);
    }

    function roll(uint256 round) external {
        require(round < getCurrentRound(), "ST02");
        require(roundStatus[round] == 0, "ST03");
        require(getRoundBetsCount(round) > 0, "ST04");
        _roll(round);
    }

    function _roll(uint256 round) internal {
        uint256 requestId = VRFCoordinatorV2_5(vrfCoordinator)
            .requestRandomWords(
                VRFV2PlusClient.RandomWordsRequest({
                    keyHash: keyHash,
                    subId: subscriptionId,
                    requestConfirmations: requestConfirmations,
                    callbackGasLimit: 2_500_000,
                    numWords: 1,
                    extraArgs: VRFV2PlusClient._argsToBytes(
                        VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                    )
                })
            );
        roundRequests[round] = requestId;
        requestRounds[requestId] = round;
        roundStatus[round] = 1;
        emit RequestedCalculation(round, requestId, block.timestamp);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        // get round by request
        uint256 round = requestRounds[requestId];
        require(round > 0, "ST09");
        // get winner offset
        uint256 winnerOffset = randomWords[0] % roundProbabilities[round][0];
        // calculate winner side by probabilities
        uint256 winnerSide = 0;
        uint256 prev = 0;
        for (uint256 i = 1; i <= 5; i++) {
            if (winnerOffset < roundProbabilities[round][i] + prev) {
                winnerSide = i;
                break;
            }
            prev += roundProbabilities[round][i];
        }
        // save winner side
        roundWinnerSide[round] = winnerSide;
        // set round status to finished
        roundStatus[round] = 2;
        emit WinnerCalculated(round, winnerSide);
    }

    function prepareExecute(
        uint256 round
    ) public view returns (uint256[] memory data) {
        uint256 roundBank;
        uint256 bonusBank;
        uint256 sideBank;
        uint256 bonusShares;
        // get winner side
        uint256 side = roundWinnerSide[round];
        roundBank = roundBankBySide[round][0];
        bonusBank = (roundBank * bonusPart) / 100_00;
        sideBank = roundBankBySide[round][side];
        roundBank -= (roundBank * core.fee()) / 100_00 + bonusBank;
        bonusShares = roundBonusSharesBySide[round][side];
        uint256[] memory roundData = new uint256[](4);
        roundData[0] = roundBank;
        roundData[1] = sideBank;
        roundData[2] = bonusShares;
        roundData[3] = bonusBank;
        return roundData;
    }

    function executeResult(
        uint256 round,
        uint256 offset,
        uint256 limit
    ) public nonReentrant {
        require(roundStatus[round] == 2, "ST03");
        // get winner side
        uint256 side = roundWinnerSide[round];
        // get data
        uint256[] memory roundData = prepareExecute(round);
        // get bets count
        uint256 betsCount = roundBetsBySide[round][side].length;
        // should not happen
        require(
            IERC20(token).balanceOf(address(this)) >=
                roundData[0] + roundData[3] - distributedInRound[round],
            "ST07"
        );
        for (uint256 i = offset; i < limit + offset; i++) {
            if (i >= betsCount) break;
            // get bet
            StonesBet bet = roundBetsBySide[round][side][i];
            if (betSettled[address(bet)]) continue;
            // get bet's amount
            uint256 value = bet.getAmount();
            // calculate bonus share
            uint256 bonusShare = (value * (betsCount - i));
            // calculate result
            uint256 result = ((value * roundData[0]) / roundData[1]) +
                ((bonusShare * roundData[3]) / roundData[2]);
            // set bet result
            bet.setResult(result);
            // set bet status
            bet.setStatus(2);
            // transfer win amount
            IERC20(token).safeTransfer(bet.getPlayer(), result);
            betSettled[address(bet)] = true;
            distributedInRound[round] += result;
        }
    }

    function settleLostBets(
        uint256 round,
        uint256 offset,
        uint256 limit
    ) public nonReentrant {
        require(roundStatus[round] == 2, "ST03");
        // get winner side
        uint256 side = roundWinnerSide[round];
        // get all other bets
        uint256 allBetsCount = roundBets[round].length;
        for (uint256 i = offset; i < limit + offset; i++) {
            if (i >= allBetsCount) break;
            StonesBet bet = roundBets[round][i];
            if (betSettled[address(bet)]) continue;

            // skip if winner side
            if (bet.getSide() == side) continue;
            // set bet status
            bet.setStatus(3);
            betSettled[address(bet)] = true;
        }
    }

    function getAddress() public view override returns (address) {
        return address(this);
    }

    function getVersion() public view override returns (uint256) {
        return created;
    }

    function getFeeType() public pure override returns (uint256) {
        return 0;
    }

    function getStaking() public view override returns (address) {
        return address(staking);
    }

    function getCurrentRound() public view returns (uint256) {
        return block.timestamp / interval;
    }

    function getRoundBetsCount(uint256 _round) public view returns (uint256) {
        return roundBets[_round].length;
    }
    function getRoundBetsCountBySide(
        uint256 _round,
        uint256 _side
    ) public view returns (uint256) {
        return roundBetsBySide[_round][_side].length;
    }

    function getRoundBank(uint256 _round) public view returns (uint256) {
        return roundBankBySide[_round][0];
    }

    function getRoundSideBank(
        uint256 _round,
        uint256 _side
    ) public view returns (uint256) {
        return roundBankBySide[_round][_side];
    }
}
