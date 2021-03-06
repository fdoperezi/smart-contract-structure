const distributeBbkToMany = async (bbk, accounts, amount) => {
  await Promise.all(
    accounts.map(account => bbk.distributeTokens(account, amount))
  )
}

const finalizedBBK = async (
  owner,
  BrickblockToken,
  bonusAddress,
  fountainAddress,
  contributors,
  tokenDistAmount
) => {
  const bbk = await BrickblockToken.new(bonusAddress, { from: owner })
  await bbk.changeFountainContractAddress(fountainAddress, { from: owner })
  await distributeBbkToMany(bbk, contributors, tokenDistAmount)
  await bbk.finalizeTokenSale({ from: owner })
  await bbk.unpause({ from: owner })
  return bbk
}

module.exports = {
  distributeBbkToMany,
  finalizedBBK
}
