with LLC;
procedure Main is
  type Alphabet is range 1 .. 100;
  type Count_Type is new Natural;
  type Count_Array is array (Alphabet) of Count_Type;
  type Length_Array is array (Alphabet) of Natural;
  max_bits : constant Positive := 16;  --  Length limit in Huffman codes
  procedure My_LLC is new LLC (Alphabet, Count_Type, Count_Array, Length_Array, max_bits);
begin
  null;
end Main;
