#+build !windows
package main

// Links are only registered on Windows; elsewhere every launch handles its own.
host_link_other_instance_running :: proc() -> bool { return false }
