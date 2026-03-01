// PauseFlowPaySchedule.cdc
// Pauses a schedule (owner only). No payouts until resumed.

import "FlowPay"

transaction(scheduleId: UInt64) {
    prepare(signer: auth(Storage) &Account) {
        let collection = signer.storage
            .borrow<auth(FlowPay.Owner) &FlowPay.ScheduleCollection>(from: FlowPay.ScheduleStoragePath)
            ?? panic("ScheduleCollection not found")

        collection.pause(id: scheduleId)
    }
}
