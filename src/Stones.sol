// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin/access/AccessControl.sol";
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
 * ST06 - transfer failed
 */

contract Stones is
    VRFConsumerBaseV2Plus,
    AccessControl,
    GameInterface,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    error RoundNotFinished(uint256 round);

    bytes32 public constant TIMELOCK = keccak256("TIMELOCK");

    uint256 private immutable created;
    uint256 private immutable subscriptionId;
    address public immutable vrfCoordinator;
    bytes32 public immutable keyHash;
    uint32 private constant callbackGasLimit = 2_500_000;
    uint16 public constant requestConfirmations = 3;
    uint32 private constant numWords = 1;

    uint256 private constant bonusPart = 5_00;

    uint256 private constant interval = 10 minutes;

    StakingInterface public immutable staking;
    CoreInterface public immutable core;

    mapping(uint256 => StonesBet[]) public roundBets;
    mapping(uint256 => mapping(uint256 => StonesBet[])) public roundBetsBySide;
    mapping(uint256 => mapping(uint256 => uint256)) public roundBankBySide;
    mapping(uint256 => mapping(uint256 => uint256)) public roundProbabilities;
    mapping(uint256 => mapping(uint256 => uint256))
        public roundBonusSharesBySide;

    mapping(uint256 => uint256) public roundWinnerSide;
    // 0 - not started
    // 1 - spinning
    // 2 - finished
    // 3 - distributed
    mapping(uint256 => uint256) public roundStatus;
    mapping(uint256 => uint256) public roundRequests;
    mapping(uint256 => uint256) public requestRounds;

    event RoundStart(uint256 indexed round, uint256 indexed timestamp);
    event PayoutDistributed(uint256 indexed round);

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
        // validation for vrf coordinator is not needed because it is already validated in the VRFConsumerBaseV2Plus contract
        vrfCoordinator = _vrfCoordinator;
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        core = CoreInterface(_core);
        require(core.isStaking(_staking), "ST06");
        staking = StakingInterface(_staking);
        created = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function placeBet(
        address _player,
        uint256 _totalAmount,
        bytes calldata _data
    ) external returns (address betAddress) {
        require(address(core) == _msgSender(), "ST00");
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
            _side
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
                    callbackGasLimit: callbackGasLimit,
                    numWords: numWords,
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

    function executeResult(uint256 round) public {
        require(roundStatus[round] == 2, "ST03");
        roundStatus[round] = 3;
        // get winner side
        uint256 side = roundWinnerSide[round];
        // get round's bank
        uint256 roundBank = roundBankBySide[round][0];
        // get side's bank
        uint256 sideBank = roundBankBySide[round][side];
        // calculate core fee
        uint256 fee = (roundBank * core.fee()) / 100_00;
        // calculate bonus bank
        uint256 bonusBank = (roundBank * bonusPart) / 100_00;
        // substract fee and bonus from bank
        roundBank -= fee + bonusBank;
        // get bonus share
        uint256 bonusShares = roundBonusSharesBySide[round][side];
        // get bets count
        uint256 betsCount = roundBetsBySide[round][side].length;
        for (uint256 i = 0; i < betsCount; i++) {
            // get bet
            StonesBet bet = roundBetsBySide[round][side][i];
            // get bet's amount
            uint256 value = bet.getAmount();
            // calculate win amount
            uint256 winAmount = (value * roundBank) / sideBank;
            // calculate bonus share
            uint256 bonusShare = (bet.getAmount() * (betsCount - i));
            // calculate bonus amount
            uint256 bonusAmount = (bonusShare * bonusBank) / bonusShares;
            // set bet result
            bet.setResult(winAmount + bonusAmount);
            // set bet status
            bet.setStatus(2);
            // transfer win amount
            IERC20(address(staking.getToken())).safeTransfer(
                bet.getPlayer(),
                winAmount + bonusAmount
            );
        }
        // get all other bets
        uint256 allBetsCount = roundBets[round].length;
        for (uint256 i = 0; i < allBetsCount; i++) {
            StonesBet bet = roundBets[round][i];
            // skip if winner side
            if (bet.getSide() == side) continue;
            // set bet status
            bet.setStatus(3);
        }
        emit PayoutDistributed(round);
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
