// GetFlowPayDueSchedules.cdc
// Returns schedule IDs that are due for payout right now for a creator.

import "FlowPay"

access(all) fun main(creatorAddress: Address): [UInt64] {
    let account = getAccount(creatorAddress)
    let cap = account.capabilities.get<&{FlowPay.ScheduleCollectionPublic}>(FlowPay.SchedulePublicPath)
        ?? panic("User has no FlowPay ScheduleCollection capability")
    let collection = cap.borrow() ?? panic("Could not borrow ScheduleCollection")
    return collection.getDueIDs()
}
