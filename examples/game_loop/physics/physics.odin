// @layer(physics)
// @forbid_import("sim", "render")
package physics

import "core:fmt"
import "core:mem"

Rigid_Body :: struct {
	pos:  [2]f32,
	vel:  [2]f32,
	mass: f32,
	id:   u32,
}

solve_broadphase :: proc(bodies: []Rigid_Body, allocator := context.allocator) {
	pairs := make([dynamic][2]int, 0, 16, allocator)
	for i in 0 ..< len(bodies) {
		for j := i + 1; j < len(bodies); j += 1 {
			dx := bodies[i].pos[0] - bodies[j].pos[0]
			if dx > -1.0 && dx < 1.0 {
				append(&pairs, [2]int{i, j})
			}
		}
	}
	_ = mem.ptr_to_bytes(&pairs)
}

solve_contacts_debug :: proc(bodies: []Rigid_Body) {
	if len(bodies) >= 2 {
		tag := format_contact_tag(bodies[0].id, bodies[1].id)
		delete(tag)
	}
}

format_contact_tag :: proc(a, b: u32) -> string {
	return fmt.aprintf("pair:%d-%d", a, b)
}
