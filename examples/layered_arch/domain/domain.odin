// @layer(domain)
// @forbid_import("service", "infra", "core:net", "core:os")
package domain

Order_Item :: struct {
	sku_id:     u64,
	quantity:   u32,
	unit_cents: i64,
}

Order :: struct {
	id:    u64,
	items: [8]Order_Item,
	count: int,
}

// @zero_alloc
// @no_temp_alloc
order_total_cents :: proc(#by_ptr order: Order) -> i64 {
	total := i64(0)
	for i in 0 ..< order.count {
		item := order.items[i]
		total += i64(item.quantity) * item.unit_cents
	}
	return total
}
