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
  @@formats = { 0x01 => 0, 0x02 => 0, 0x03 => 0 }
  ((' '.ord)..('_'.ord)).each { |ch| @@formats[ch] = 1 } # add ASCII
  (0x80 .. 0xFF).each { |ch| @@formats[ch] = 2 } # symbols

  uint8 :value_format
  choice :val, selection: lambda { @@formats[value_format.to_i] }  do
    uint16 0  # hex, bin, dec
    string 1, read_length: 0  # ASCII character
    string 2, read_length: lambda { value_format - 0x80 } # symbol
  end

  def decode
    type = @@formats[value_format.to_i]
    case type
    when 0
      case value_format.to_i
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
      value_format.chr  # ASCII char
    when 2
      val  # symbol
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
#  def decode
#    "#{symbol}=#{val.decode}"
#  end
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
  raise "Empty string for parsing #{klass}" if str.empty?
  xx = (0...str.size).map {|i| str[i].ord.to_s(16)}
  #puts "BEFORE klass=#{klass}  r: [#{xx.join(' ')}] }"  
  record = klass.read str
  #puts "MIDDLE klass=#{klass} num_bytes=#{record.num_bytes}  r: '#{str}'"
  str.slice!(0, record.num_bytes)
  #puts "AFTER klass=#{klass} r: '#{str}'"
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
    if r[0] == "'"
      i = r.index("'", 1)
      out += r.slice!(0, i+1)
    else
      term = parse(ExpressionTerm, r)
      out += term.decode
    end
  end
  [out, comment]
end

class RowInstr < BaseRecord
  uint16 :data

  @@reg = {
            0 => '', 
            1 => 'B', 2 => 'C', 3 => 'D', 4 => 'E',5 => 'H', 6 => 'L', 7 => 'A',
            8 => 'BC', 9 => 'DE', 0xA => 'HL',
            0x10 => 'NZ', 0x12 => 'NC',
            0x18 => '(HL)', 0x1A => '(DE)', 0x1C => '(C)',
            0x27 => :symbol, 0x28 => :symbol_indirect,
          }

  attr_accessor :symbol, :comment

  def self.parse_instr(row, str)
    object = parse(self, str)
    object.symbol, object.comment = (row.instr_size > 0) ? expression(str) : ['', '']
    object
  end

  def arg b
    raise "Unknown argument code #{b.to_i.to_s(16)}" unless @@reg.key? b
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

templates = {  # instructions
  0xE0B8 => "JP\t{{symbol}}\t{{comment}}",
  0xE11C => "DJNZ\t{{symbol}}\t{{comment}}",

  0xDE10 => "CPL",  
  0xDD84 => "CP\t{{arg1}}\t{{comment}}",
  0xDD8E => "CP\t{{arg1}}\t{{comment}}",
  0xDD98 => "CP\t{{arg1}}\t{{comment}}",


  0xE0F4 => "JR\t{{arg1}},{{arg2}}\t{{comment}}",
  0xE0CC => "JR\t{{arg1}}\t{{comment}}",
  0xE0EA => "JR\t{{arg1}},{{arg2}}\t{{comment}}",

  0xE126 => "CALL\t{{symbol}}\t{{comment}}",
  0xE13A => "RET\t{{comment}}",
  0xDE42 => "HALT\t{{comment}}",

  0xDB5E => "PUSH\t{{arg1}}\t{{comment}}",
  0xDB7C => "POP\t{{arg1}}\t{{comment}}",
  
  0xDDB6 => "INC\t{{arg1}}\t{{comment}}",
  0xDEB0 => "INC\t{{arg1}}\t{{comment}}",

  0xDDDE => "DEC\t{{arg1}}\t{{comment}}",
  0xDECE => "DEC\t{{arg1}}\t{{comment}}",

  0xDC26 => "ADD\t{{arg1}},{{arg2}}\t{{comment}}",
  0xDC30 => "ADD\t{{arg1}},{{arg2}}\t{{comment}}",

  0xDD52 => "XOR\t{{arg1}}\t{{comment}}",

  0xDA00 => "LD\t{{arg1}},{{arg2}}\t{{comment}}",
  0xDB18 => "LD\t{{arg1}},{{arg2}}\t{{comment}}",


  0xE1A8 => "OUT\t{{arg1}},{{arg2}}\t{{comment}}",
  0xE1B2 => "OUT\t{{arg1}},{{arg2}}\t{{comment}}",
  0xE16C => "IN\t{{arg1}},{{arg2}}\t{{comment}}"

}

misc_templates = {
  0xE1E6 => "PUT\t{{expr}}\t{{comment}}",
  0xE1E4 => "ORG\t{{expr}}\t{{comment}}",
  0xE1EB => "{{expr}}:\t{{comment}}", # label
  0xE1E8 => "DEFW\t{{{expr}}}\t{{comment}}",
  0xE1E7 => "DEFB\t{{{expr}}}\t{{comment}}",
  0xE1EA => "DEFS\t{{{expr}}}\t{{comment}}",
  
  0xE1E9 => "DEFM\t{{{expr}}}\t{{comment}}"

}

File.open(source_file, 'r') do |mzf|
  h = MzfHeader.read mzf
  puts "type=#{h.ftype.to_i.to_s(16)}h size=#{h.fsize} name: #{h.name}"
  
  until mzf.eof?
    row = Row.read mzf    
    r = String(row.line)

    row_code = row.row_type.to_i
    row_code = 0xDA00 if row_code & 0xFF00 == 0xDA00   # several LDs

    if templates.key? row_code
      inst = RowInstr.parse_instr(row, r)
      line = Mustache.new
      line[:arg1] = inst.arg1
      line[:arg2] = inst.arg2
      line[:symbol] = inst.symbol
      line[:comment] = inst.comment
      line.template = templates[row_code]
      puts line.render
      next
    end

    if misc_templates.key? row_code
      expr, comment = expression(r)
      line = Mustache.new
      line[:expr] = expr 
      line[:comment] = comment
      line.template = misc_templates[row_code]
      puts line.render
      next
    end

    case row.row_type
    when 0xE1ED  # comment only
      puts r
    when 0xE1EC  # symbol definition
      sym = parse(RowSymbol, r)
p sym      
      expr, comment = expression(r)
      puts "#{sym.symbol}=#{expr}\t#{comment}"
#    when 0xE1E9  # DEFM
#      puts "DEFM\t#{r}"

    when  0xe0cc
      inst = parse(RowInstr, r)
      print "UNKNOWN INSTRUCTION data #{inst.decode(row.row_type)}  size #{row.instr_size}  "
      puts row.instr_size > 1 ? expression(r) : ''

    else
      raise "Unknown row type= 0x#{row.row_type.to_i.to_s(16)}"  
    end
  end
end


