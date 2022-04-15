import { ethers } from "hardhat";
import chai from "chai";
import { solidity } from "ethereum-waffle";

import { deployVaults } from "../scripts/helpers/deploy-vaults";
import { config } from "../scripts/utils/config";

chai.use(solidity);
const { expect } = chai;

it("Deploy Vaults", async () => {
  const { l1Vault, l2Vault } = await deployVaults(
    config.l1Governance,
    config.l2Governance,
    process.env.ETH_NETWORK || "eth-goerli-fork",
    process.env.POLYGON_NETWORK || "polygon-mumbai-fork",
    config,
  );

  // If tokens are set correctly, most likely everything else is.
  expect(await l2Vault.token()).to.equal(config.l2USDC);
  expect(await l1Vault.token()).to.equal(config.l1USDC);

  const forwarder = await l2Vault.trustedForwarder();
  expect(forwarder).to.be.properAddress;
  expect(forwarder).to.not.equal(ethers.constants.AddressZero);
  expect(forwarder).to.equal(config.forwarder);

  // Check that staging addresses are the same
  const l1Staging = await l1Vault.staging();
  expect(l1Staging).to.be.properAddress;
  expect(l1Staging).to.equal(await l2Vault.staging());
});

// TODO: check that we can upgrade proxies successfully
