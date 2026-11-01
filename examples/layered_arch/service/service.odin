// @layer(service)
// @forbid_import("infra", "core:net")
package service

import "../domain"

// @zero_alloc
// @no_temp_alloc
validate_and_price :: proc(#by_ptr order: domain.Order) -> (cents: i64, ok: bool) {
	if order.count <= 0 || order.count > len(order.items) {
		return 0, false
	}
	total := domain.order_total_cents(order)
	return total, total >= 0
}
