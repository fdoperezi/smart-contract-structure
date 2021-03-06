pragma solidity ^0.4.8;

import "zeppelin-solidity/contracts/token/StandardToken.sol";


// Proof-of-Asset contract representing a token backed by a foreign asset.
contract POAToken is StandardToken {

    // Event emitted when a state change occurs.
    event Stage(Stages stage);

    // Event emitted when tokens are bought
    event Buy(address buyer, uint256 amount);

    // Event emitted when tokens are sold
    event Sell(address seller, uint256 amount);

    // Event emitted when dividends are paid out
    event Payout(uint256 amount);

    // The owner of this contract
    address public owner;

    // The name of this PoA Token
    string public name;

    // The symbol of this PoA Token
    string public symbol;

    // amount of decimals used for this Token
    // this would be better as a constant, but linter won't let me
    uint8 public decimals = 18;


    // The broker managing this contract
    address public broker;

    // The custodian holding the assets for this contract
    address public custodian;

    // The time when the contract was created
    uint public creationTime;

    // The time available to fund the contract
    uint public timeout;

    // An account carrying a +balance+ and +claimedPayout+ value.
    struct Account {
        uint256 balance;
        uint256 claimedPayout;
    }

    // Mapping of Account per address
    mapping(address => Account) accounts;

    mapping(address => uint256) unliquidated;

    uint256 totalPayout = 0;

    enum Stages {
        Funding,
        Pending,
        Failed,
        Active
    }

    Stages public stage = Stages.Funding;

    // Ensure current stage is +_stage+
    modifier atStage(Stages _stage) {
        require(stage == _stage);
        _;
    }

    modifier onlyBroker() {
        require(msg.sender == broker);
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    // Enter given stage +_stage+
    function enterStage(Stages _stage) {
        stage = _stage;
        Stage(_stage);
    }

    // Ensure funding timeout hasn't expired
    modifier checkTimeout() {
        if (stage == Stages.Funding &&
            now >= creationTime.add(timeout))
            enterStage(Stages.Failed);
        _;
    }

    // Create a new POAToken contract.
    function POAToken(
        string _name,
        string _symbol,
        address _broker,
        address _custodian,
        uint _timeout,
        uint256 _supply
    ) {
        owner = msg.sender;
        name = _name;
        symbol = _symbol;
        broker = _broker;
        custodian = _custodian;
        timeout = _timeout;
        creationTime = now;
        totalSupply = _supply;
        accounts[owner].balance = _supply;
    }

    /* Buy PoA tokens from the contract.
     * Called by any investor during the +Funding+ stage.
     */
    function buy() payable
        checkTimeout atStage(Stages.Funding)
    {
        /* SafeMath will do these checks for us
        /* require(accounts[owner].balance >= msg.value); */
        /* require(accounts[msg.sender].balance + msg.value > accounts[msg.sender].balance); */
        accounts[owner].balance = accounts[owner].balance.sub(msg.value);
        accounts[msg.sender].balance = accounts[msg.sender].balance.add(msg.value);
        Buy(msg.sender, msg.value);

        if (accounts[owner].balance == 0)
            enterStage(Stages.Pending);
    }

    /* Activate the PoA contract, providing a valid proof-of-assets.
     * Called by the broker or custodian after assets have been received into the DTF account.
     * This verifies that the provided signature matches the expected symbol/amount and
     * was made with the custodians private key.
     */
    function activate(uint8 _v, bytes32 _r, bytes32 _s)
        checkTimeout atStage(Stages.Pending)
    {
        bytes32 hash = sha3(symbol, bytes32(totalSupply));
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 prefixedHash = sha3(prefix, hash);

        address sigaddr = ecrecover(
            prefixedHash,
            _v,
            _r,
            _s
        );

        if (sigaddr == custodian) {
            broker.transfer(this.balance);
            enterStage(Stages.Active);
        }
    }

    /* Reclaim funds after failed funding run.
     * Called by any investor during the `Failed` stage.
     */
    function reclaim()
        checkTimeout atStage(Stages.Failed)
    {
        uint256 balance = accounts[msg.sender].balance;
        accounts[msg.sender].balance = 0;
        msg.sender.transfer(balance);
    }

    /* Sell PoA tokens back to the contract.
     * Called by any investor during the `Active` stage.
     * This will subtract the given +amount+ from the users
     * token balance and saves it as unliquidated balance.
     */
    function sell(uint256 _amount)
        atStage(Stages.Active)
    {
        /* SafeMath will do this check for us */
        /* require(accounts[msg.sender].balance >= amount); */
        accounts[msg.sender].balance = accounts[msg.sender].balance.sub(_amount);
        unliquidated[msg.sender] = unliquidated[msg.sender].add(_amount);
        Sell(msg.sender, _amount);
    }

    /* Provide funds from liquidated assets.
     * Called by the broker after liquidating assets.
     * This checks if the user has unliquidated balances
     * and transfers the value to the user.
     */
    function liquidated(address _account) payable
        atStage(Stages.Active)
        onlyBroker
    {
         /* SafeMath will do this check for us */
         /* require(unliquidated[account] >= msg.value); */
        unliquidated[_account] = unliquidated[_account].sub(msg.value);
        totalSupply = totalSupply.sub(msg.value);
        (_account.transfer(msg.value));  // (making solium happy)
    }

    /* Provide funds from a dividend payout.
     * Called by the broker after the asset yields dividends.
     * This will simply add the received value to the stored `payout`.
     */
    function payout() payable
        atStage(Stages.Active)
    {
        require(msg.value > 0);
        totalPayout = totalPayout.add(msg.value.mul(10e18).div(totalSupply));
        Payout(msg.value);
    }

    function currentPayout(Account _account) internal returns (uint256) {
        uint256 totalUnclaimed = totalPayout.sub(_account.claimedPayout);
        return _account.balance.mul(totalUnclaimed).div(10e18);
    }

    /* Claim dividend payout.
     * Called by any investor after dividends have been received.
     * This will calculate the payout, subtract any already claimed payouts,
     * update the claimed payouts for the given account, and send the payout.
     */
    function claim()
        atStage(Stages.Active)
    {
        uint256 payoutAmount = currentPayout(accounts[msg.sender]);
        require(payoutAmount > 0);
        accounts[msg.sender].claimedPayout = totalPayout;
        msg.sender.transfer(payoutAmount);
    }

    // Transfer +_value+ from sender to account +_to+.
    function transfer(address _to, uint256 _value) returns (bool) {
        // send any remaining unclaimed payouts to msg.sender
        uint256 payoutAmount = currentPayout(accounts[msg.sender]);
        if (payoutAmount > 0)
            msg.sender.transfer(payoutAmount);

        // shift balances
        accounts[msg.sender].balance = accounts[msg.sender].balance.sub(_value);
        accounts[_to].balance = accounts[_to].balance.add(_value);

        // set claimed payouts to max for both accounts
        accounts[msg.sender].claimedPayout = totalPayout;
        accounts[_to].claimedPayout = totalPayout;

        Transfer(msg.sender, _to, _value);
        return true;
    }

    // Get balance of given address +_account+.
    function balanceOf(address _account) constant returns (uint256 balance) {
        return accounts[_account].balance;
    }

    // TODO: needed to test dividend payouts until we implement real changing supply
    function debugSetSupply(uint256 _supply) onlyOwner {
        totalSupply = _supply;
    }

}
