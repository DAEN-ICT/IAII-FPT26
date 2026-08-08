connect -url TCP:localhost:3121
after 500
puts "FPGATTEN_JTAG_TARGETS_BEGIN"
puts [targets]
puts "FPGATTEN_JTAG_TARGETS_END"
disconnect
exit
