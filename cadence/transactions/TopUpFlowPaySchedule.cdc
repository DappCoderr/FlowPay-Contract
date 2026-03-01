// TopUpFlowPaySchedule.cdc
// Adds more FLOW to an active or paused schedule's escrow.

import "FlowPay"
import "FlowToken"
import "FungibleToken"

transaction(scheduleId: UInt64, amount: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        let vaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow signer's FlowToken vault")

        let funds <- vaultRef.withdraw(amount: amount) as! @FlowToken.Vault

        let collection = signer.storage
            .borrow<&FlowPay.ScheduleCollection>(from: FlowPay.ScheduleStoragePath)
            ?? panic("ScheduleCollection not found")  // read-only for topUp

        collection.topUp(id: scheduleId, funds: <-funds)
    }
}
