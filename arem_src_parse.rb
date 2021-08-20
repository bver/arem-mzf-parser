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
  @@formats = { 0x01 => 0, 0x02 => 0, 0x03 => 0, 0x04 => 3, 0x05 => 4 }
  ((' '.ord)..('_'.ord)).each { |ch| @@formats[ch] = 1 } # add ASCII
  (0x80 .. 0xFF).each { |ch| @@formats[ch] = 2 } # symbols

  uint8 :value_format
  choice :val, selection: lambda { @@formats[value_format.to_i] }  do
    uint16 0  # hex, bin, dec
    string 1, read_length: 0  # ASCII character
    string 2, read_length: lambda { value_format - 0x80 } # symbol
    string 3, read_length: 1  # prefixed ASCII character
    string 4, read_length: 1  # prefixed VIDEO character
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
    when 3
      "'#{val}'"
    when 4
      "V'#{val}'"      
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
            8 => 'BC', 9 => 'DE', 0xA => 'HL', 0xB => 'SP', 0xC => 'IX', 0xD => 'IY', 0xE => 'AF', 0xF => "AF'",
            0x10 => 'NZ', 0x11 => 'Z', 0x12 => 'NC', 0x13 => 'C', 0x14 => 'PO', 0x15 => 'PE', 0x16 => 'P', 0x17 => 'M',
            0x18 => '(HL)', 0x19 => '(BC)', 0x1A => '(DE)', 0x1B => '(SP)', 0x1C => '(C)', 0x1D => '(IX)', 0x1E => '(IY)',
            0x27 => :symbol, 0x28 => :symbol_indirect, 0x29 => :symbol_ind_ix, 0x2A => :symbol_ind_iy
          }

  attr_accessor :symbol, :comment

  def self.parse_instr(row, str)
    object = parse(self, str)
    object.symbol, object.comment = (row.instr_size > 0) ? expression(str) : ['', '']
    object
  end

  def arg(b, symbol)
    raise "Unknown argument code #{b.to_i.to_s(16)}" unless @@reg.key? b
    arg = @@reg[b]
    (arg == 'symbol') ? symbol : arg
    case arg
    when :symbol
      symbol
    when :symbol_indirect
      "(#{symbol})"
    when :symbol_ind_ix
      "(IX#{symbol})"
    when :symbol_ind_iy
      "(IY#{symbol})"
    else
      arg
    end
  end

  def arg1
    symbol = @symbol.split(',').first
    arg(data.to_i & 0x00FF, symbol)
  end
  
  def arg2
    symbol = @symbol.split(',').last
    arg((data.to_i & 0xFF00) >> 8, symbol)
  end

  def decode(data1)
    b1 = (data1.to_i & 0xFF00) >> 8
    b2 = data1.to_i & 0x00FF
    b3 = (data.to_i & 0xFF00) >> 8
    b4 = data.to_i & 0x00FF
    "#{b1.to_s(16)} #{b2.to_s(16)} #{b3.to_s(16)} #{b4.to_s(16)} arg1:#{@@reg[b4.to_i]}, @arg2:#{@@reg[b3.to_i]}"
  end
end

instructions = {
  44 => 'EXX',
  48 => 'LDI',
  49 =>	'LDIR',
  50 => 'LDD',	
  51 => 'LDDR',
  52 => 'CPI',
  53 =>	'CPIR',
  54 => 'CPD',
  55 =>	'CPDR',
  104 => 'DAA',
  105 => 'CPL',
  106 => 'NEG',
  107 => 'CCF',
  108 => 'SCF',
  109 => 'NOP',
  110 => 'HALT',
  111 => 'DI',
  112 => 'EI',
  113 => 'IM0',
  114 => 'IM1',
  115 => 'IM2',
  116 => 'ADD',
  117 => 'ADC',
  118 => 'SBC',
  127 => 'RLCA',
  128 => 'RLA',
  129 => 'RRCA',
  130 => 'RRA',
  159 => 'RLD',
  160 => 'RRD',
  183 => 'DJNZ',
  188 => 'RETI',
  189 => 'RETN',
  190 => 'RST',
  193 => 'INI',
  194 => 'INIR',
  195 => 'IND',
  196 => 'INDR',
  199 => 'OUTI',
  200 => 'OTIR',
  201 => 'OUTD',
  202 => 'OTDR'
}

(1..35).each {|k| instructions[k] = 'LD' }     #       35
(36..38).each {|k| instructions[k] = 'PUSH' }  #	3
(39..41).each {|k| instructions[k] = 'POP' }   #	3
(42..43).each {|k| instructions[k] = 'EX' }    #	2
(45..47).each {|k| instructions[k] = 'EX' }    #	3
(56..60).each {|k| instructions[k] = 'ADD' }   #	5
(61..65).each {|k| instructions[k] = 'ADC' }   #	5
(66..70).each {|k| instructions[k] = 'SUB' }   #	5
(71..75).each {|k| instructions[k] = 'SBC' }   #	5
(76..80).each {|k| instructions[k] = 'AND' }   #	5
(81..85).each {|k| instructions[k] = 'OR' }    #	5
(86..90).each {|k| instructions[k] = 'XOR' }   #	5
(91..95).each {|k| instructions[k] = 'CP' }    #	5
(96..99).each {|k| instructions[k] = 'INC' }   #	4
(100..103).each {|k| instructions[k] = 'DEC' } #	4
(119..120).each {|k| instructions[k] = 'ADD' } #	2
(121..123).each {|k| instructions[k] = 'INC' } #	3
(124..126).each {|k| instructions[k] = 'DEC' } #	3
(131..134).each {|k| instructions[k] = 'RLC' } #	4
(135..138).each {|k| instructions[k] = 'RL' }  #	4
(139..142).each {|k| instructions[k] = 'RRC' } #	4
(143..146).each {|k| instructions[k] = 'RR' }  #	4
(147..150).each {|k| instructions[k] = 'SLA' } #	4
(151..154).each {|k| instructions[k] = 'SRA' } #	4
(155..158).each {|k| instructions[k] = 'SRL' } #	4
(161..164).each {|k| instructions[k] = 'BIT' } #	4
(165..168).each {|k| instructions[k] = 'SET' } #	4
(169..172).each {|k| instructions[k] = 'RES' } #	4
(173..174).each {|k| instructions[k] = 'JP' }  #	2
(175..179).each {|k| instructions[k] = 'JR' }  #	5
(180..182).each {|k| instructions[k] = 'JP' }  #	3
(184..185).each {|k| instructions[k] = 'CALL' }#	2
(186..187).each {|k| instructions[k] = 'RET' } #	2
(191..192).each {|k| instructions[k] = 'IN' }  #	2
(197..198).each {|k| instructions[k] = 'OUT' } #	2

templates = {
  0xE1E6 => 'PUT',
  0xE1E4 => 'ORG',
  0xE1E8 => 'DEFW',
  0xE1E7 => 'DEFB',
  0xE1EA => 'DEFS',
  0xE1E9 => 'DEFM'
}

File.open(source_file, 'r') do |mzf|
  h = MzfHeader.read mzf
  #puts "type=#{h.ftype.to_i.to_s(16)}h size=#{h.fsize} name: #{h.name}"
  raise "File type #{h.ftype.to_i.to_s(16)}H not supported" unless h.ftype == 0x41

  until mzf.eof?
    row = Row.read mzf    
    r = String(row.line)

    row_code = row.row_type.to_i

    instr_key = ((row_code - 0xDA00) / 10) + 1
    if instructions.key? instr_key
      inst = RowInstr.parse_instr(row, r)
      line = instructions[instr_key]
      line += "\t#{inst.arg1}" unless inst.arg1.empty?
      line += ",#{inst.arg2}" unless inst.arg2.empty?
      line += "\t#{inst.comment}" unless inst.comment.empty?
      puts line
      next
    end

    if templates.key? row_code
      expr, comment = expression(r)
      line = templates[row_code] + "\t#{expr}"
      line += "\t#{comment}" unless comment.empty?
      puts line
      next
    end

    case row.row_type
    when 0xE1EB  # label
      expr, comment = expression(r)
      line = expr + ':'
      line += "\t#{comment}" unless comment.empty?
      puts line
    when 0xE1ED  # comment only
      puts r
    when 0xE1EC  # symbol definition
      sym = parse(RowSymbol, r)
      expr, comment = expression(r)
      puts "#{sym.symbol}=#{expr}\t#{comment}"

#    when  0xDA1E
#      inst = parse(RowInstr, r)
#      print "UNKNOWN INSTRUCTION data #{inst.decode(row.row_type)}  size #{row.instr_size}  "
#      puts row.instr_size > 1 ? expression(r) : ''

    else
      raise "Unknown row type= 0x#{row.row_type.to_i.to_s(16)}"  
    end
  end
end


