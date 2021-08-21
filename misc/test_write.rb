#!/bin/env ruby

require 'bindata'

class BaseRecord < BinData::Record
  endian :little
end

class MzfHeader < BaseRecord
  uint8  :ftype, :value => 0x41 
  string :name, length: 16
  uint8  :name_term, :value => 0x0d
  uint16 :fsize
  uint16 :fstart
  uint16 :fexec
  string :comment, length: 104
end

INSTR_SIZE = 1+1+2+1+1+1 #TODO: comment

class InstrRow < BaseRecord
  uint8 :row_length, :value => 1+1+2+2+1
  uint8 :instr_size
  uint16 :row_type
  uint8 :arg_1
  uint8 :arg_2
#  string :comment, :value => lambda { "; #{row_type.to_i}" }
  uint8  :line_term, :value => 0  # 0x00
end

FIRST = 0xDA00
LAST = 0xE1E4
STEP = 10
instructions = ((LAST - FIRST) / STEP).to_i

hdr = MzfHeader.new
hdr.name = "POKUS\r"
hdr.fsize = INSTR_SIZE * instructions
hdr.fstart = 0x8000
hdr.fexec = instructions

File.open('pokus.mzf', 'wb') do |io|
  hdr.write io
  (FIRST ... LAST).step(STEP).each do |row_type|
    instr = InstrRow.new
    instr.instr_size = 1
    instr.arg_1 = 1 # B
    instr.arg_2 = 2 # C
    instr.row_type = row_type
    instr.write io
  end
end

