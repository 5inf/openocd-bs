# File by Paul Fertser
# Dowloaded from https://sourceforge.net/p/openocd/mailman/message/31813979/
# 
# Init global variables to work with the boundary scan register the
# first argument is tap name, the second is BSR length.
#
# If BSR length is omitted or zero, the script tries to perform
# auto-detection; if there're additional devices present in the chain
# _after_ the given one, you need to pass their quantity as postlen
proc init_bs {tap {len 0} {postlen 0}} {
    global bsrtap bsrlen
    set bsrtap $tap
    # disable polling for the cpu TAP as it should be kept in BYPASS
    poll off
    extest_mode

    if {$len == 0} {
	set bsrlen [detect_drlen $postlen]
    } else {
	set bsrlen $len
    }
    init_bsrstate
}

# Connect BSR to the boundary scan logic
proc extest_mode {} {
    global bsrtap
    # EXTEST
    irscan $bsrtap 0
}

# Enter standard bypass mode
proc bypass_mode {} {
    global bsrtap
    # BYPASS
    irscan $bsrtap 0xFFFFFFFF
}

# Write bsrstateout to target and store the result in bsrstate
#
# If pause is true, end in drpause state so the values shifted in are
# not acted upon
proc exchange_bsr {{pause 0}} {
    global bsrtap bsrstate bsrstateout
    set scan_cmd [concat $bsrtap $bsrstateout]
    if {$pause} {
	append scan_cmd " -endstate drpause"
    }
    update_bsrstate [eval drscan $scan_cmd]
    return $bsrstate
}

# Check if particular bit is set in bsrstate
#
# If register is specified, use it instead of global bsrstate
proc get_bit_bsr {bit {register 0}} {
    global bsrstate
    if {$register == 0} {
	set register $bsrstate
    }
    set idx [expr $bit / 32]
    set bit [expr $bit % 32]
    expr ([lindex $register [expr $idx*2 + 1]] & [expr 2**$bit]) != 0
}

# Resample and get bit
proc sample_get_bit_bsr {bit} {
    exchange_bsr
    get_bit_bsr $bit
}

# Set particular bit to "value" in bsrstateout
proc set_bit_bsr {bit value} {
    global bsrstateout
    set idx [expr ($bit / 32) * 2 + 1]
    set bit [expr $bit % 32]
    set bitval [expr 2**$bit]
    set word [lindex $bsrstateout $idx]
    if {$value == 0} {
	set word [format %X [expr $word & ~$bitval]]
    } else {
	set word [format %X [expr $word | $bitval]]
    }
    set bsrstateout [lreplace $bsrstateout $idx $idx 0x$word]
    return
}

# Set the bit and update BSR on target
proc set_bit_bsr_do {bit value} {
    set_bit_bsr $bit $value
    exchange_bsr
}

# Sample BSR n times and store the dictionary of floating values to
# global floatingpins variable
proc prepare_detect_bsrchange {{n 4}} {
    global floatingpins
    set floatingpins ""
    exchange_bsr
    for {set i 0} {$i < $n} {incr i} {
	set f [detect_bsrchange]
	foreach x [dict keys $f] {
	    dict set floatingpins $x [dict get $f $x]
	}
    }
}

# Sample BSR and output bit numbers that changed comparing to the
# previous values omitting those present in the global floatingpins
# variable
proc show_bsrchange {} {
    global floatingpins
    set d [detect_bsrchange]
    foreach i [dict keys $d] {
	if {![dict exists $floatingpins $i]} {
	    set v [dict get $d $i]
	    echo [concat "Bit " $i " changed " [lindex $v 0] "->" [lindex $v 1]]
	}
    }
}

# Try to find bits that control the given pin You should have a pullup
# (use curpull 1) or pulldown (use curpull 0) connected while
# running this
proc find_pin_ctrl {pin curpull} {
    detect_pin_change $pin [expr $pin + 1] $curpull
    detect_pin_change $pin [expr $pin - 2] $curpull
}

proc init_bsrstate {} {
    global bsrtap bsrlen bsrstate bsrstateout
    set bsrstate ""
    for {set i $bsrlen} {$i > 32} {incr i -32} {
	append bsrstate 32 " " 0xFFFFFFFF " "
    }
    if {$i > 0} {
	append bsrstate $i " " 0xFFFFFFFF
    }
    set bsrstateout $bsrstate
    # reenter extest mode to get default BSR contents
    bypass_mode
    extest_mode
    # stop in drpause to avoid disturbing the board
    exchange_bsr 1
    set bsrstateout $bsrstate
    exchange_bsr
    return
}

proc update_bsrstate {state} {
    global bsrstate
    set i 1
    foreach word $state {
	set bsrstate [lreplace $bsrstate $i $i 0x$word]
	incr i 2
    }
}

proc detect_drlen {{postlen 0}} {
    global bsrtap bsrstate bsrstateout
    # assume maximum length is 4096 bits
    set maxlen 4096
    set bsrstateout ""
    for {set i $maxlen} {$i > 0} {incr i -32} {
	append bsrstateout 32 " " 0 " "
    }
    for {set i $maxlen} {$i > 0} {incr i -32} {
	append bsrstateout 32 " " 0xFFFFFFFF " "
    }
    set bsrstate $bsrstateout
    # stop in drpause
    exchange_bsr 1
    for {set i [expr $maxlen * 2 - 1]} {$i >= 0} {incr i -1} {
	if {[get_bit_bsr $i] == 0} {
	    break
	}
    }
    set bsrlen [expr $i - $maxlen + 1 - $postlen]
    echo "Auto-detected BSR length: "$bsrlen
    return $bsrlen
}

proc detect_bsrchange {} {
    global bsrstate bsrlen
    set pinschanged ""
    set prevbsrstate $bsrstate
    exchange_bsr
    for {set i 0} {$i < $bsrlen} {incr i} {
	set is [get_bit_bsr $i $prevbsrstate]
	set cs [get_bit_bsr $i]
	if {$is != $cs} {
	    dict set pinschanged $i "$is $cs"
	}
    }
    return $pinschanged
}

proc detect_pin_change {pin ctrl curpull} {
    global bsrstateout bsrlen
    if {$ctrl < 0 || ($ctrl+1) >= $bsrlen} {
	return
    }
    exchange_bsr
    set bsrstateout_saved $bsrstateout
    for {set i 0} {$i < 4} {incr i} {
	set_bit_bsr $ctrl [expr $i / 2]
	set_bit_bsr_do [expr $ctrl + 1] [expr $i % 2]
	if {[sample_get_bit_bsr $pin] != $curpull} {
	    echo [concat "Pin " $pin " pulled to " [expr !$curpull] " by " \
		      $ctrl " = " [expr $i / 2] ", " \
		      [expr $ctrl + 1] " = " [expr $i % 2]]
	}
    }
    set bsrstateout $bsrstateout_saved
    exchange_bsr
    return
}
