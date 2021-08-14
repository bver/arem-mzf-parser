#!/bin/env ruby

require 'bindata'

abort "Usage:\n #$0 source.arem.mzf" unless ARGV.size == 1
source_file = ARGV.first

class BaseRecord < BinData::Record
  endian :little
end

class MzfHeader < BaseRecord
  uint8  :ftype
  string :name, read_length: 16
  uint8  :name_term  # 0x0d
  uint16 :fsize
  uint16 :fstart
  uint16 :fexec
  string :comment, read_length: 104
  virtual assert: lambda { name_term == 0xd or name_term == 0 }
end

class ExpressionTerm < BaseRecord
  @@formats = { 1 => 0, 2 => 0, 3 => 0, 
                '+'.ord => 1, '-'.ord => 1, '*'.ord => 1, '/'.ord => 1 }
  @@formats.default = 2
  uint8 :value_format
  choice :val, selection: lambda { @@formats[value_format] }  do
    uint16 0  # hex, bin, dec
    string 1, read_length: 0
    string 2, read_length: lambda { value_format - 0x80 } 
  end
  def decode
      type = @@formats[value_format]
      case type
      when 0
        case value_format
           when 1
             val.to_i.to_s(16) + 'H'
           when 2
             val.to_i.to_s(2) + 'B'
           when 3
             val.to_s
           else
             raise "Unknown ExpressionTerm format=#{value_format}"
        end
      when 1
        value_format.chr
      when 2
        val
      else 
        raise "Unknown ExpressionTerm type=#{type}"
      end
  end
end

class RowSymbol < BaseRecord
  uint8 :sym_len
  string :symbol, read_length: lambda { sym_len - 0x80 }
  uint8 :assign_sign
  virtual assert: lambda { assign_sign == '='.ord }
  def decode
    "#{symbol}=#{val.decode}"
  end
end

class Row < BaseRecord
  uint8 :row_length
  uint8 :instr_size
  uint16 :row_type
  string :line, read_length: lambda { row_length - 5 }
  uint8  :line_term  # 0x00
  virtual assert: lambda { line_term == 0 }
end

def parse(klass, str)
  record = klass.read str
  str.slice!(0, record.num_bytes)
  record
end

def expression(r)  # TODO: return val, comment
  out = ''
  until r.empty?
    if r[0] == ';'
      out += " #{r}" # comment
      r = ''
      break
    end
    term = parse(ExpressionTerm, r)
    out += term.decode
  end
  out
end

class RowInstr < BaseRecord
  uint16 :data
end

File.open(source_file, 'r') do |mzf|
  h = MzfHeader.read mzf
  puts "type=#{h.ftype.to_i.to_s(16)}h size=#{h.fsize} name: #{h.name}"
  
  until mzf.eof?
    row = Row.read mzf    
    r = String(row.line)
    case row.row_type
    when 0xE1ED  #comment
      puts r
    when 0xE1EC  #symbol definition
      sym = parse(RowSymbol, r)
      puts "#{sym.symbol}=#{expression(r)}"
    when 0xE1E6
      puts "PUT #{expression(r)}"
    when 0xE1E4  #ORG
      puts "ORG #{expression(r)}"
    when 0xE1EB  #label
      puts "#{expression(r)}:"
    when 0xE1E8  #DEFW
      puts "DEFW #{expression(r)}"
    when 0xE1E7  #DEFB
      puts "DEFB #{expression(r)}"
    when 0xE1EA  #DEFS
      puts "DEFS #{expression(r)}"
    when 0xE1E9  #DEFM
      puts "DEFM #{r}"




    when 0xE0B8, 0xdb5e, 0xdad2, 0xe126, 0xddb6, 0xdb7, 0xe11c, 0xdb7c, 0xe13a
      inst = parse(RowInstr, r)
      print "UNKNOWN INSTRUCTION data #{row.row_type.to_i.to_s(16)} inst #{inst.data. to_i.to_s(16)}  size #{row.instr_size}  "
      puts row.instr_size > 1 ? expression(r) : ''


    else
      raise "Unknown row type=0x#{row.row_type.to_i.to_s(16)}"  
    end
  end
end


