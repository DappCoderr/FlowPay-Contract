// GetFlowPaySchedule.cdc
// Returns ScheduleInfo for one schedule by creator address and schedule ID, or nil.

import "FlowPay"

access(all) fun main(creatorAddress: Address, scheduleId: UInt64): FlowPay.ScheduleInfo? {
    let account = getAccount(creatorAddress)
    let cap = account.capabilities.get<&{FlowPay.ScheduleCollectionPublic}>(FlowPay.SchedulePublicPath)
        ?? panic("Creator has no FlowPay ScheduleCollection capability")
    let collection = cap.borrow() ?? panic("Could not borrow ScheduleCollection")
    return collection.getScheduleInfo(id: scheduleId)
}
