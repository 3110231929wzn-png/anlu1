


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// Parenthesize macro expressions: without this, nested expansion evaluates
// 64000000/1000000000/125000000/... to zero and disables periodic refresh.
`define   SDR_CLK_PERIOD                  (1000000000 / 50000000)
// EM638325 requires 4096 refresh commands per 64 ms (Rev.3.2).
// This requirement is independent of the controller row-address width.
`define   SDR_REFRESH_CYCLES              4096
`define   SELF_REFRESH_INTERVAL           (64000000 / `SDR_CLK_PERIOD / `SDR_REFRESH_CYCLES)

