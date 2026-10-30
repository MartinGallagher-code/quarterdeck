# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""quarterdeck -- where the instruments are read and the runs are logged.

The command is `qd`.  It fans commands out across a fleet and keeps what
came back as a dataset, drives the toolchain beside it (binnacle,
matrix_orchestrator, iperf_orchestrator, datacenter_visualization) and
keeps their output the same way, and reads any of it back -- tables,
statistics, diffs, outliers, a full-screen explorer, or the floor plan.
"""

VERSION = "0.2.0"
