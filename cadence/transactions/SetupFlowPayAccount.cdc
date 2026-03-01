// SetupFlowPayAccount.cdc
// Run once per user before creating schedules.
// Creates ScheduleCollection, publishes public capability, registers Execute
// capability with FlowPayTransactionHandler, and creates Scheduler Manager.

import "FlowPay"
import "FlowPayTransactionHandler"
import "FlowTransactionSchedulerUtils"

transaction() {
    prepare(signer: auth(Storage, Capabilities) &Account) {

        if signer.storage.borrow<&AnyResource>(from: FlowPay.ScheduleStoragePath) == nil {
            let collection <- FlowPay.createScheduleCollection()
            signer.storage.save(<-collection, to: FlowPay.ScheduleStoragePath)

            let publicCap = signer.capabilities.storage
                .issue<&{FlowPay.ScheduleCollectionPublic}>(FlowPay.ScheduleStoragePath)
            signer.capabilities.publish(publicCap, at: FlowPay.SchedulePublicPath)
        }

        let execCap = signer.capabilities.storage
            .issue<auth(FlowPay.Execute) &FlowPay.ScheduleCollection>(FlowPay.ScheduleStoragePath)

        FlowPayTransactionHandler.registerExecuteCapability(
            creator: signer.address,
            cap:     execCap
        )

        if !signer.storage.check<@{FlowTransactionSchedulerUtils.Manager}>(
            from: FlowTransactionSchedulerUtils.managerStoragePath
        ) {
            let manager <- FlowTransactionSchedulerUtils.createManager()
            signer.storage.save(<-manager, to: FlowTransactionSchedulerUtils.managerStoragePath)

            let managerCap = signer.capabilities.storage
                .issue<&{FlowTransactionSchedulerUtils.Manager}>(
                    FlowTransactionSchedulerUtils.managerStoragePath
                )
            signer.capabilities.publish(managerCap, at: FlowTransactionSchedulerUtils.managerPublicPath)
        }
    }

    execute {
        log("FlowPay account setup complete")
    }
}
