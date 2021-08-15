#!/bin/env ruby

require 'bindata'
require 'mustache'

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

def expression(r)
  out, comment = ['', '']
  until r.empty?
    if r[0] == ';'
      comment = r
      r = ''
      break
    end
    term = parse(ExpressionTerm, r)
    out += term.decode
  end
  [out, comment]
end

class RowInstr < BaseRecord
  uint16 :data

  @@reg = {1 => 'B', 2 => 'C', 3 => 'D', 4 => 'E',5 => 'H', 6 => 'L', 7 => 'A',
           8 => 'BC', 9 => 'DE', 0xA => 'HL', 
           0x27 => :symbol, 0x28 => :symbol_indirect }
  @@reg.default = '?'

  attr_accessor :symbol, :comment

  def self.parse_instr(row, str)
    object = parse(self, str)
    object.symbol, object.comment = (row.instr_size > 0) ? expression(str) : ['', '']
    object
  end

  def arg b
    arg = @@reg[b]
    (arg == 'symbol') ? @symbol : arg
    case arg
    when :symbol
      @symbol
    when :symbol_indirect
      "(#{@symbol})"
    else
      arg
    end
  end

  def arg1
    arg(data.to_i & 0x00FF)
  end
  
  def arg2
    arg((data.to_i & 0xFF00) >> 8)
  end

  def decode(data1)
    b1 = (data1.to_i & 0xFF00) >> 8
    b2 = data1.to_i & 0x00FF
    b3 = (data.to_i & 0xFF00) >> 8
    b4 = data.to_i & 0x00FF
    "#{b1.to_s(16)} #{b2.to_s(16)} #{b3.to_s(16)} #{b4.to_s(16)} arg1:#{@@reg[b4.to_i]}, @arg2:#{@@reg[b3.to_i]}"
  end
end

templates = {
  0xE0B8 => "JP\t{{symbol}}\t{{comment}}",
  0xE11C => "DJNZ\t{{symbol}}\t{{comment}}",

  0xE126 => "CALL\t{{symbol}}\t{{comment}}",
  0xE13A => "RET\t{{comment}}",

  0xDB5E => "PUSH\t{{arg1}}\t{{comment}}",
  0xDB7C => "POP\t{{arg1}}\t{{comment}}",
  
  0xDDB6 => "INC\t{{arg1}}\t{{comment}}",
  0xDDDE => "DEC\t{{arg1}}\t{{comment}}",
  0xDC26 => "ADD\t{{arg1}},{{arg2}}\t{{comment}}",

  0xdad2 => "LD\t{{arg1}},{{arg2}}\t{{comment}}",
  0xda00 => "LD\t{{arg1}},{{arg2}}\t{{comment}}",
  0xDA0A => "LD\t{{arg1}},{{arg2}}\t{{comment}}",

}

File.open(source_file, 'r') do |mzf|
  h = MzfHeader.read mzf
  puts "type=#{h.ftype.to_i.to_s(16)}h size=#{h.fsize} name: #{h.name}"
  
  until mzf.eof?
    row = Row.read mzf    
    r = String(row.line)

    if templates.key? row.row_type.to_i
      inst = RowInstr.parse_instr(row, r)
      line = Mustache.new
      line[:arg1] = inst.arg1
      line[:arg2] = inst.arg2
      line[:symbol] = inst.symbol
      line[:comment] = inst.comment
      line.template = templates[row.row_type.to_i]
      puts line.render
      next
    end

    case row.row_type
    when 0xE1ED  #comment only
      puts r
    when 0xE1EC  #symbol definition
      sym = parse(RowSymbol, r)
      expr, comment = expression(r)
      puts "#{sym.symbol}=#{expr}\t#{comment}"
    when 0xE1E6
      expr, comment = expression(r)
      puts "PUT\t#{expr}\t#{comment}"
    when 0xE1E4  #ORG
      expr, comment = expression(r)
      puts "ORG\t#{expr}\t#{comment}"
    when 0xE1EB  #label
      expr, comment = expression(r)
      puts "#{expr}:\t#{comment}"
    when 0xE1E8  #DEFW
      expr, comment = expression(r)
      puts "DEFW\t#{expr}\t#{comment}"
    when 0xE1E7  #DEFB
      expr, comment = expression(r)
      puts "DEFB\t#{expr}\t#{comment}"
    when 0xE1EA  #DEFS
      expr, comment = expression(r)
      puts "DEFS\t#{expr}\t#{comment}"
    when 0xE1E9  #DEFM
      puts "DEFM\t#{r}"

    when 0x0db7, 0xe1a8
      inst = parse(RowInstr, r)
      print "UNKNOWN INSTRUCTION data #{inst.decode(row.row_type)}  size #{row.instr_size}  "
      puts row.instr_size > 1 ? expression(r) : ''

    else
      raise "Unknown row type=0x#{row.row_type.to_i.to_s(16)}"  
    end
  end
end


