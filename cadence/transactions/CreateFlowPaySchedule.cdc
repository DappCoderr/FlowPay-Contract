// CreateFlowPaySchedule.cdc
// Creates a new recurring payout schedule, escrows FLOW, adds to collection,
// and schedules the first automated payout via FlowTransactionScheduler.

import "FlowPay"
import "FlowPayTransactionHandler"
import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowToken"
import "FungibleToken"

transaction(
    recipientAddresses: [Address],
    recipientAmounts:   [UFix64],
    intervalSeconds:   UFix64,
    totalPayouts:      UInt64,
    label:             String,
    delayFirstPayout:  UFix64
) {
    prepare(signer: auth(Storage, Capabilities) &Account) {

        pre {
            recipientAddresses.length == recipientAmounts.length
                : "recipientAddresses and recipientAmounts must have same length"
            recipientAddresses.length > 0 : "Must have at least 1 recipient"
        }

        var recipients: [FlowPay.RecipientEntry] = []
        var totalPerPayout: UFix64 = 0.0
        var i = 0
        while i < recipientAddresses.length {
            recipients.append(
                FlowPay.RecipientEntry(
                    address: recipientAddresses[i],
                    amount:  recipientAmounts[i]
                )
            )
            totalPerPayout = totalPerPayout + recipientAmounts[i]
            i = i + 1
        }

        let totalDeposit = totalPerPayout * UFix64(totalPayouts)

        let collection = signer.storage
            .borrow<&FlowPay.ScheduleCollection>(from: FlowPay.ScheduleStoragePath)
            ?? panic("ScheduleCollection not found. Run SetupFlowPayAccount first.")

        let vaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow signer's FlowToken vault")

        let escrow <- vaultRef.withdraw(amount: totalDeposit) as! @FlowToken.Vault

        let schedule <- FlowPay.createSchedule(
            creator:         signer.address,
            recipients:      recipients,
            intervalSeconds: intervalSeconds,
            totalPayouts:    totalPayouts,
            label:           label,
            funds:           <-escrow
        )

        let scheduleId = schedule.id

        collection.addSchedule(schedule: <-schedule)

        let future = getCurrentBlock().timestamp + delayFirstPayout

        let callData = FlowPayTransactionHandler.PayoutCallData(
            creatorAddress: signer.address,
            scheduleId:     scheduleId
        )

        let est = FlowTransactionScheduler.estimate(
            data:            callData,
            timestamp:       future,
            priority:        FlowTransactionScheduler.Priority.Medium,
            executionEffort: 2000
        )

        assert(
            est.timestamp != nil || FlowTransactionScheduler.Priority.Medium == FlowTransactionScheduler.Priority.Low,
            message: est.error ?? "Scheduler estimation failed"
        )

        let feeVaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow signer's FlowToken vault for fees")

        let fees <- feeVaultRef.withdraw(amount: est.flowFee ?? 0.0) as! @FlowToken.Vault

        let manager = signer.storage
            .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                from: FlowTransactionSchedulerUtils.managerStoragePath
            ) ?? panic("Manager not found. Run SetupFlowPayAccount first.")

        let freshHandlerCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                FlowPayTransactionHandler.HandlerStoragePath
            )

        manager.schedule(
            handlerCap:      freshHandlerCap,
            data:            callData,
            timestamp:       future,
            priority:        FlowTransactionScheduler.Priority.Medium,
            executionEffort: 2000,
            fees:            <-fees
        )

        log("FlowPay schedule #".concat(scheduleId.toString()).concat(" created. First payout at: ").concat(future.toString()))
    }
}
