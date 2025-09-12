// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// src/User.sol

contract User {
    struct UserInfo {
        string username;
    }

    mapping(address => UserInfo) public users;

    event RegisterUser(address indexed userAddress, string username);

    function registerUser(string calldata username) external {
        require(bytes(username).length > 0, "Username cannot be empty");
        users[msg.sender] = UserInfo(username);
        emit RegisterUser(msg.sender, username);
    }
}

