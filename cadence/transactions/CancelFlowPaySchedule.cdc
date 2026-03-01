// CancelFlowPaySchedule.cdc
// Cancels a schedule and refunds remaining escrow to the creator.

import "FlowPay"
import "FlowToken"
import "FungibleToken"

transaction(scheduleId: UInt64) {
    prepare(signer: auth(Storage) &Account) {
        let collection = signer.storage
            .borrow<auth(FlowPay.Owner) &FlowPay.ScheduleCollection>(from: FlowPay.ScheduleStoragePath)
            ?? panic("ScheduleCollection not found")

        let vaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow signer's FlowToken vault")

        collection.cancel(id: scheduleId, creatorVaultRef: vaultRef)
    }
}
