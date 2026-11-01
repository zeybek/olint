// @layer(sim)
// @forbid_import("render")
package sim

import "../physics"
import "core:mem"

World :: struct {
	bodies: [64]physics.Rigid_Body,
	count:  int,
}

// @zero_alloc
integrate_velocities :: proc(w: ^World, dt: f32) {
	for i in 0 ..< w.count {
		b := &w.bodies[i]
		b.pos[0] += b.vel[0] * dt
		b.pos[1] += b.vel[1] * dt
	}
}

// @zero_alloc
step_world_with_arena :: proc(w: ^World, dt: f32, scratch_buf: []byte) {
	arena: mem.Arena
	mem.arena_init(&arena, scratch_buf)
	arena_alloc := mem.arena_allocator(&arena)

	integrate_velocities(w, dt)
	physics.solve_broadphase(w.bodies[:w.count], arena_alloc)
}

// Intentionally broken when demonstrating `olint` catching transitive allocations:
// `step_world_leaky` calls `physics.solve_contacts_debug`, which calls `physics.format_contact_tag`
// (`fmt.aprintf` on `context.allocator`).
step_world_leaky :: proc(w: ^World, dt: f32) {
	integrate_velocities(w, dt)
	physics.solve_contacts_debug(w.bodies[:w.count])
}
