connect -url TCP:localhost:3121
after 300

puts "FPGATTEN_RUNTIME_TARGETS_BEGIN"
puts [targets]
puts "FPGATTEN_RUNTIME_TARGETS_END"

targets -set -nocase -filter {name =~ "*A53*#0"}
puts "FPGATTEN_A53_0_STATE=[state]"

targets -set -nocase -filter {name =~ "*MicroBlaze PMU*"}
puts "FPGATTEN_PMU_STATE=[state]"

targets -set -nocase -filter {name =~ "*PSU*"}
puts "FPGATTEN_CSR_VERSION_READ_BEGIN"
puts [mrd 0xA0010044 1]
puts [mrd 0xA0010084 1]
puts "FPGATTEN_CSR_VERSION_READ_END"

disconnect
exit
