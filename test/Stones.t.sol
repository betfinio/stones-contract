// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "forge-std/console.sol";
import "../src/Stones.sol";
import "../src/shared/Token.sol";
import "../src/shared/Core.sol";
import "./ConservativeStakingMock.sol";
contract StonesTest is Test {
    Stones public stones;
    Core public core;
    Token public token;
    Pass public pass;
    BetsMemory public betsMemory;
    ConservativeStakingMock public staking;
    Partner public partner;
    address public alice = address(1);
    address public bob = address(2);
    address public carol = address(3);

    function setUpCore() public {
        token = new Token(address(this));
        staking = new ConservativeStakingMock(address(token));
        betsMemory = new BetsMemory(address(this));
        pass = new Pass(address(this));
        betsMemory.grantRole(betsMemory.TIMELOCK(), address(this));
        betsMemory.setPass(address(pass));
        pass.mint(alice, address(0), address(0));
        core = new Core(
            address(token),
            address(betsMemory),
            address(pass),
            address(this)
        );
        betsMemory.addAggregator(address(core));
        token.transfer(address(core), 1_000_000 ether);
        core.grantRole(core.TIMELOCK(), address(this));
        address tar = core.addTariff(0, 1_00, 0);
        partner = Partner(core.addPartner(tar));
    }

    function setUp() public {
        setUpCore();
        core.addStaking(address(staking));
        stones = new Stones(
            555,
            address(core),
            address(staking),
            0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed,
            0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f,
            address(this)
        );
        core.grantRole(core.TIMELOCK(), address(this));
        core.addGame(address(stones));
        token.transfer(address(staking), 1_000_000 ether);
        token.transfer(address(alice), 100 ether);
        vm.startPrank(alice);
        token.approve(address(core), 100 ether);
        vm.stopPrank();
        vm.mockCall(
            address(pass),
            abi.encodeWithSelector(
                AffiliateMember.getInviter.selector,
                address(0)
            ),
            abi.encode(address(1))
        );
        token.transfer(alice, 1_000_000 ether);
        token.transfer(bob, 1_000_000 ether);
        token.transfer(carol, 1_000_000 ether);
        vm.mockCall(
            address(pass),
            abi.encodeWithSelector(ERC721.balanceOf.selector, bob),
            abi.encode(address(1))
        );
        vm.mockCall(
            address(pass),
            abi.encodeWithSelector(ERC721.balanceOf.selector, carol),
            abi.encode(address(1))
        );
    }

    function testConstructor() public view {
        assertEq(address(stones.core()), address(core));
        assertEq(address(stones.staking()), address(staking));
        assertEq(stones.getAddress(), address(stones));
    }
    function testConstructor_invalid() public {
        vm.expectRevert(bytes("ST06"));
        stones = new Stones(
            555,
            address(core),
            address(111),
            0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed,
            0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f,
            address(this)
        );
    }
    function testPlaceBet_fail() public {
        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);
        bytes memory data = abi.encode(1000, 1, 0);
        vm.expectRevert(bytes("ST00"));
        stones.placeBet(alice, 1000 ether, data);

        vm.expectRevert(bytes("PA01"));
        partner.placeBet(address(stones), 0 ether, data);

        vm.expectRevert(bytes("ST01"));
        partner.placeBet(address(stones), 500 ether, data);

        vm.expectRevert(bytes("ST01"));
        data = abi.encode(1000, 6, 0);
        partner.placeBet(address(stones), 1000 ether, data);

        vm.expectRevert(bytes("ST02"));
        data = abi.encode(1000, 1, 345345);
        partner.placeBet(address(stones), 1000 ether, data);
    }
    function testPlaceBetValid() public {
        // Approve some tokens for core
        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);

        // Place a bet with valid data
        uint256 betAmount = 1000;
        uint256 side = 2; // Choose a valid side
        uint256 round = stones.getCurrentRound();

        // Call the placeBet function
        address betAddress = partner.placeBet(
            address(stones),
            betAmount * 1 ether,
            abi.encode(betAmount, side, round)
        );

        // Assertions
        assertEq(stones.getRoundBetsCount(round), 1); // One bet in the round
        StonesBet bet = StonesBet(betAddress); // Cast address to StonesBet
        assertEq(bet.getPlayer(), alice);
        assertEq(bet.getAmount(), betAmount * 1 ether);
        assertEq(bet.getSide(), side);
        assertEq(bet.getCreated(), block.timestamp);
        assertEq(bet.getStatus(), 1);
        assertEq(bet.getResult(), 0);
    }

    function testPlaceBetInvalidAmount() public {
        // Approve some tokens for core
        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);

        // Try to place a bet with an invalid amount (not a multiple of 1 ether)
        uint256 betAmount = 1000;
        uint256 side = 2;
        uint256 round = stones.getCurrentRound();

        // Expect a revert
        vm.expectRevert(bytes("ST01"));
        partner.placeBet(
            address(stones),
            betAmount,
            abi.encode(betAmount, side, round)
        );
    }

    function testPlaceBetInvalidSide() public {
        // Approve some tokens for core
        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);

        // Try to place a bet with an invalid side
        uint256 betAmount = 1000;
        uint256 side = 6; // Choose an invalid side
        uint256 round = stones.getCurrentRound();

        // Expect a revert
        vm.expectRevert(bytes("ST01"));
        partner.placeBet(
            address(stones),
            betAmount * 1 ether,
            abi.encode(betAmount, side, round)
        );
    }

    function testMultipleBets_sameSide() public {
        uint256 round = stones.getCurrentRound();

        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);
        partner.placeBet(
            address(stones),
            1000 ether,
            abi.encode(1000, 2, round)
        );
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(core), 1000 ether);
        partner.placeBet(
            address(stones),
            1000 ether,
            abi.encode(1000, 2, round)
        );
        vm.stopPrank();
        vm.startPrank(carol);
        token.approve(address(core), 1000 ether);
        partner.placeBet(
            address(stones),
            1000 ether,
            abi.encode(1000, 2, round)
        );
        vm.stopPrank();

        assertEq(stones.getRoundBetsCount(round), 3);
        assertEq(stones.getRoundBank(round), 3000 ether);
        assertEq(stones.getRoundSideBank(round, 1), 0 ether);
        assertEq(stones.getRoundSideBank(round, 2), 3000 ether);
        assertEq(stones.getRoundSideBank(round, 3), 0 ether);
        assertEq(stones.getRoundSideBank(round, 4), 0 ether);
        assertEq(stones.getRoundSideBank(round, 5), 0 ether);
    }

    function testMultipleBets_diffSide() public {
        uint256 round = stones.getCurrentRound();

        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);
        partner.placeBet(
            address(stones),
            1000 ether,
            abi.encode(1000, 1, round)
        );
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(core), 1000 ether);
        partner.placeBet(
            address(stones),
            1000 ether,
            abi.encode(1000, 2, round)
        );
        vm.stopPrank();
        vm.startPrank(carol);
        token.approve(address(core), 1000 ether);
        partner.placeBet(
            address(stones),
            1000 ether,
            abi.encode(1000, 3, round)
        );
        vm.stopPrank();

        assertEq(stones.getRoundBetsCount(round), 3);
        assertEq(stones.getRoundBank(round), 3000 ether);
        assertEq(stones.getRoundSideBank(round, 1), 1000 ether);
        assertEq(stones.getRoundSideBank(round, 2), 1000 ether);
        assertEq(stones.getRoundSideBank(round, 3), 1000 ether);
        assertEq(stones.getRoundSideBank(round, 4), 0 ether);
        assertEq(stones.getRoundSideBank(round, 5), 0 ether);
    }

    event RoundStart(uint256 indexed round, uint256 indexed timestamp);

    function testEmit_onPlaceBet() public {
        vm.startPrank(alice);
        bytes memory data = abi.encode(1000, 1, 0);
        token.approve(address(core), 1000 ether);
        vm.expectEmit(address(stones));
        emit RoundStart(0, block.timestamp);
        partner.placeBet(address(stones), 1000 ether, data);
    }

    function placeBet(
        address player,
        uint256 amount,
        uint256 side,
        uint256 round
    ) internal returns (address) {
        vm.startPrank(player);
        token.approve(address(core), amount * 1 ether);
        address bet = partner.placeBet(
            address(stones),
            amount * 1 ether,
            abi.encode(amount, side, round)
        );
        vm.stopPrank();
        return bet;
    }

    function getRequest(uint256 requestId) internal {
        vm.mockCall(
            0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed,
            abi.encodeWithSelector(
                VRFCoordinatorV2_5.requestRandomWords.selector,
                VRFV2PlusClient.RandomWordsRequest({
                    keyHash: bytes32(
                        0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f
                    ),
                    subId: uint256(555),
                    requestConfirmations: uint16(3),
                    callbackGasLimit: uint32(2_500_000),
                    numWords: uint32(1),
                    extraArgs: VRFV2PlusClient._argsToBytes(
                        VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                    )
                })
            ),
            abi.encode(requestId)
        );
    }

    function testRoll() public {
        uint256 round = stones.getCurrentRound();
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(bytes("ST04")); // no bets
        stones.roll(round);
        vm.warp(block.timestamp + 1 days);
        round = stones.getCurrentRound();
        placeBet(alice, 1000, 1, round);
        placeBet(alice, 1000, 2, round);
        placeBet(alice, 1000, 3, round);
        placeBet(alice, 1000, 4, round);
        placeBet(alice, 1000, 5, round);
        assertEq(stones.getRoundBank(round), 5000 ether);

        vm.expectRevert(bytes("ST02")); // not finished
        stones.roll(round);

        getRequest(5);
        vm.warp(block.timestamp + 1 days);
        stones.roll(round);
        vm.expectRevert(bytes("ST03")); // do not roll again
        stones.roll(round);
    }

    event Transfer(address indexed from, address indexed to, uint256 value);

    function testFullfill_sameUser() public {
        vm.warp(1 days);
        uint256 round = stones.getCurrentRound();
        placeBet(alice, 1000, 1, round);
        placeBet(alice, 1000, 2, round);
        placeBet(alice, 1000, 3, round);
        placeBet(alice, 1000, 4, round);
        placeBet(alice, 1000, 5, round);
        assertEq(stones.roundStatus(round), 0);

        vm.warp(block.timestamp + 1 days);
        getRequest(5);
        stones.roll(round);
        assertEq(stones.roundStatus(round), 1);

        uint256[] memory result = new uint256[](1);
        result[0] = uint256(1);
        vm.startPrank(stones.vrfCoordinator());
        stones.rawFulfillRandomWords(5, result);

        assertEq(stones.roundWinnerSide(round), 1);
        assertEq(stones.roundStatus(round), 2);

        vm.expectEmit(address(token));
        emit Transfer(address(stones), alice, 4820 ether);
        assertEq(stones.roundStatus(round), 2);
        stones.executeResult(round);
        assertEq(stones.roundStatus(round), 3);
        vm.expectRevert(bytes("ST03"));
        stones.executeResult(round);
    }
    function testFullfill_multipleUsers_diffStones() public {
        vm.warp(1 days);
        uint256 round = stones.getCurrentRound();
        placeBet(alice, 1000, 1, round);
        address bet = placeBet(bob, 1000, 3, round);
        placeBet(carol, 1000, 5, round);
        assertEq(stones.roundStatus(round), 0);

        vm.warp(block.timestamp + 1 days);
        getRequest(5);
        stones.roll(round);
        assertEq(stones.roundStatus(round), 1);

        uint256[] memory result = new uint256[](1);
        result[0] = uint256(1500); // winner is 3 (bob)
        vm.startPrank(stones.vrfCoordinator());
        stones.rawFulfillRandomWords(5, result);

        assertEq(stones.roundWinnerSide(round), 3);
        assertEq(stones.roundStatus(round), 2);

        vm.expectEmit(address(token));
        emit Transfer(address(stones), bob, 2892 ether);
        stones.executeResult(round);
        assertEq(stones.roundStatus(round), 3);
        assertEq(StonesBet(bet).getStatus(), 2);
        assertEq(StonesBet(bet).getResult(), 2892 ether);
        (
            address _player,
            address _game,
            uint256 _amount,
            uint256 _result,
            uint256 _status,
            uint256 _created
        ) = StonesBet(bet).getBetInfo();
        assertEq(_player, bob);
        assertEq(_game, address(stones));
        assertEq(_amount, 1000 ether);
        assertEq(_result, 2892 ether);
        assertEq(_status, 2);
        assertEq(_created, block.timestamp - 1 days);
    }

    function testFuzz_multipleResult(uint32 result) public {
        vm.warp(1 days);
        uint256 round = stones.getCurrentRound();
        placeBet(alice, 1000, 1, round);
        placeBet(bob, 1000, 3, round);
        placeBet(carol, 1000, 5, round);
        assertEq(stones.roundStatus(round), 0);

        vm.warp(block.timestamp + 1 days);
        getRequest(5);
        stones.roll(round);
        assertEq(stones.roundStatus(round), 1);

        uint256[] memory results = new uint256[](1);
        results[0] = result;
        vm.startPrank(stones.vrfCoordinator());
        stones.rawFulfillRandomWords(5, results);
        uint256[] memory probs = new uint256[](6);
        probs[0] = 3000;
        probs[1] = 1000;
        probs[2] = 0;
        probs[3] = 1000;
        probs[4] = 0;
        probs[5] = 1000;
        assertEq(stones.roundWinnerSide(round), getWinSide(result, probs));
        assertEq(stones.roundStatus(round), 2);
    }

    function getWinSide(
        uint256 value,
        uint256[] memory probs
    ) public pure returns (uint256) {
        uint winnerOffset = value % probs[0];
        uint256 winnerSide = 0;
        uint256 prev = 0;
        for (uint256 i = 1; i <= 5; i++) {
            if (winnerOffset < probs[i] + prev) {
                winnerSide = i;
                break;
            }
            prev += probs[i];
        }
        return winnerSide;
    }

    function test1000Bets() public {
        vm.warp(1 days);
        uint256 round = stones.getCurrentRound();
        for (uint160 i = 1000; i < 2000; i++) {
            vm.mockCall(
                address(pass),
                abi.encodeWithSelector(ERC721.balanceOf.selector, address(i)),
                abi.encode(address(1))
            );
            token.transfer(address(i), 1000 ether);
            vm.startPrank(address(i));
            token.approve(address(core), 1000 ether);
            vm.stopPrank();
            placeBet(address(i), 1000, (i % 5) + 1, round);
        }
        assertEq(stones.getRoundBetsCount(round), 1000);
        assertEq(stones.getRoundBank(round), 1000 * 1000 ether);
        assertEq(stones.getRoundSideBank(round, 1), 200 * 1000 ether);
        assertEq(stones.getRoundSideBank(round, 2), 200 * 1000 ether);
        assertEq(stones.getRoundSideBank(round, 3), 200 * 1000 ether);
        assertEq(stones.getRoundSideBank(round, 4), 200 * 1000 ether);
        assertEq(stones.getRoundSideBank(round, 5), 200 * 1000 ether);

        vm.warp(block.timestamp + 1 days);
        getRequest(5);
        stones.roll(round);

        uint256[] memory results = new uint256[](1);
        results[0] = 1;
        vm.startPrank(stones.vrfCoordinator());
        stones.rawFulfillRandomWords(5, results);
    }
}
