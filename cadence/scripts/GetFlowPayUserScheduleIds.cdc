// GetFlowPayUserScheduleIds.cdc
// Returns all schedule IDs for a user (creator address).

import "FlowPay"

access(all) fun main(creatorAddress: Address): [UInt64] {
    let account = getAccount(creatorAddress)
    let cap = account.capabilities.get<&{FlowPay.ScheduleCollectionPublic}>(FlowPay.SchedulePublicPath)
        ?? panic("User has no FlowPay ScheduleCollection capability")
    let collection = cap.borrow() ?? panic("Could not borrow ScheduleCollection")
    return collection.getIDs()
}
