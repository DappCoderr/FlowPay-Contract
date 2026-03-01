// ResumeFlowPaySchedule.cdc
// Resumes a paused schedule (owner only).

import "FlowPay"

transaction(scheduleId: UInt64) {
    prepare(signer: auth(Storage) &Account) {
        let collection = signer.storage
            .borrow<auth(FlowPay.Owner) &FlowPay.ScheduleCollection>(from: FlowPay.ScheduleStoragePath)
            ?? panic("ScheduleCollection not found")

        collection.resume(id: scheduleId)
    }
}
