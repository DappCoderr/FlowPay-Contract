// GetFlowPayAllSchedulesForUser.cdc
// Returns ScheduleInfo for every schedule owned by the given creator address.

import "FlowPay"

access(all) fun main(creatorAddress: Address): [FlowPay.ScheduleInfo] {
    let account = getAccount(creatorAddress)
    let cap = account.capabilities.get<&{FlowPay.ScheduleCollectionPublic}>(FlowPay.SchedulePublicPath)
        ?? panic("User has no FlowPay ScheduleCollection capability")
    let collection = cap.borrow() ?? panic("Could not borrow ScheduleCollection")
    let ids = collection.getIDs()
    let result: [FlowPay.ScheduleInfo] = []
    for id in ids {
        if let info = collection.getScheduleInfo(id: id) {
            result.append(info)
        }
    }
    return result
}
