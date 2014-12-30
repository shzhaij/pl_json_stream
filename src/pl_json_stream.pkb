create or replace package body PL_JSON_STREAM as 
   
   MAX_BUF_LMT constant number := 4096;
   MAX_PK_LMT constant number := 1024;
   ESCAPE_CHARS constant varchar2(8) := '"' || '\' || '/' || 'b' || 'f' || 'n' || 'r' || 't';
   ESCAPE_VALUES constant varchar2(8) := '"' || '\' || '/' || CHR(8) || CHR(12) || CHR(10) || CHR(13) || CHR(9);
   
   function IS_WS_CHAR(C in char) return boolean is
   begin
      return C in (CHR(32), CHR(9), CHR(10), CHR(13), CHR(0));
   end;
   
   function IS_SP_CHAR(C in char) return boolean is
   begin
      return C in ('[', ']', '{', '}', ',', ':');
   end;
   
   procedure NEXT_PAGE(CTX in out T_PARSE_CONTEXT) is
   begin
      if (CTX.IDX > CTX.TOTAL_LEN) then
         return;
      end if;
      CTX.BUF_IDX := 1;
      CTX.BUF_LMT := MAX_BUF_LMT;
      if (MAX_BUF_LMT > CTX.TOTAL_LEN - CTX.IDX + 1) then
         CTX.BUF_LMT := CTX.TOTAL_LEN - CTX.IDX + 1;
      end if;
      CTX.BUF := SUBSTR(CTX.STR_DATA, CTX.IDX, CTX.BUF_LMT);
   end;
   
   procedure PUSH_BACK(CTX in out T_PARSE_CONTEXT, STR varchar) is
   N number := LENGTH(STR);
   begin
      if (CTX.PB_LMT + N > MAX_PK_LMT) then
         RAISE_APPLICATION_ERROR(- 20601, 'PUSH BACK BUFFER OVERFLOW');
      end if;
      if (CTX.PB_LMT > 0 and CTX.PB_IDX > CTX.PB_LMT) then
         CTX.PB := '';
         CTX.PB_IDX := 1;
         CTX.PB_LMT := 0;
      end if;
    --MOVE PUSH BACK TO START AT OFFSET 1
      if (CTX.PB_IDX + CTX.PB_LMT + N - 1 > MAX_PK_LMT) then
         CTX.PB := SUBSTR(CTX.PB, CTX.PB_IDX, CTX.PB_LMT);
         CTX.PB_IDX := 1;
      end if;
      CTX.PB := CTX.PB || STR;
      CTX.PB_LMT := CTX.PB_LMT + N;
      CTX.IDX := CTX.IDX - N;
   end;
   
   function NEXT_C(CTX in out T_PARSE_CONTEXT, L in number default 1) return varchar is
   S number := L;
   T number;
   STR varchar2(32767);
   begin
      if (CTX.STR_DATA is null) then
         return null;
      end if;
      while true loop
         exit when CTX.IDX > CTX.TOTAL_LEN or S < 1;
         T := S;
      --exhaust push back first
         if (CTX.PB is not null and CTX.PB_IDX <= CTX.PB_LMT) then
            if (CTX.PB_LMT - CTX.PB_IDX + 1 < S) then
               T := CTX.PB_LMT - CTX.PB_IDX + 1;
            end if;
            STR := STR || SUBSTR(CTX.PB, CTX.PB_IDX, T);
            CTX.PB_IDX := CTX.PB_IDX + T;
            CTX.IDX := CTX.IDX + T;
            S := S - T;
         elsif (CTX.BUF_IDX > CTX.BUF_LMT) then
            NEXT_PAGE(CTX);
         else
            if (CTX.BUF_LMT - CTX.BUF_IDX + 1 < S) then
               T := CTX.BUF_LMT - CTX.BUF_IDX + 1;
            end if;
            STR := STR || SUBSTR(CTX.BUF, CTX.BUF_IDX, T);
            CTX.BUF_IDX := CTX.BUF_IDX + T;
            CTX.IDX := CTX.IDX + T;
            S := S - T;
         end if;
      end loop;
      return STR;
   end;
   
   function ESCAPE_C(C in varchar2) return char is
   begin
      return SUBSTR(ESCAPE_VALUES, INSTR(ESCAPE_CHARS, C, 1, 1), 1);
   end;
   
   function TO_UNI_C(STR in varchar2) return char is
   begin
      return UNISTR('\' || LPAD(STR, 4, '0'));
   end;
   
   procedure NEXT_STR(CTX in out T_PARSE_CONTEXT, E in out T_JSON_EVENT) is
   STATE number(1) := 0;
   CH char(1);
   UNI_C varchar(4);
   begin
      while true loop
         exit when CTX.IDX > CTX.TOTAL_LEN;
         CH := NEXT_C(CTX);
         if (STATE = 0) then
            if (CH = '"') then
               STATE := 1;
            else
               RAISE_APPLICATION_ERROR(- 20601, 'Invalid string "' || E.TOKEN || '" found at position ' || CTX.IDX);
            end if;
         elsif (STATE = 1) then
            if (CH = '"') then
               STATE := 4;
               exit;
            elsif (CH = '\') then
               STATE := 2;
            else
               STATE := 1;
               E.TOKEN := E.TOKEN || CH;
            end if;
         elsif (STATE = 2) then
            if (INSTR(ESCAPE_CHARS, CH, 1, 1) > 0) then
               STATE := 1;
               E.TOKEN := E.TOKEN || ESCAPE_C(CH);
            elsif (CH = 'u') then
               STATE := 3;
               UNI_C := '';
            else
               RAISE_APPLICATION_ERROR(- 20601, 'Invalid escape character ''\' || CH || ''' found at position ' || CTX.IDX);
            end if;
         elsif (STATE = 3) then
            if (CH >= '0' and CH <= '9' or UPPER(CH) >= 'A' and UPPER(CH) <= 'F' and LENGTH(UNI_C) < 4) then
               UNI_C := UNI_C || CH;
               STATE := 3;
            else
               E.TOKEN := E.TOKEN || TO_UNI_C(UNI_C);
               STATE := 1;
               PUSH_BACK(CTX, CH);
            end if;
         end if;
      end loop;
      E.EVENT := EVT_JSON_V_STR;
   end;
   
   procedure NEXT_EXP(CTX in out T_PARSE_CONTEXT, E in out T_JSON_EVENT) is
   STATE number(1) := 0;
   CH char(1);
   begin
      while true loop
         exit when CTX.IDX > CTX.TOTAL_LEN;
         CH := NEXT_C(CTX);
         if (STATE = 0) then
            if (CH in ('E', 'e')) then
               STATE := 1;
            else
               RAISE_APPLICATION_ERROR(- 20601, 'Invalid exponent ' || E.TOKEN || ' found at position ' || CTX.IDX);
            end if;
            E.TOKEN := E.TOKEN || CH;
         elsif (STATE = 1) then
            if (CH in ('-', '+')) then
               STATE := 2;
            elsif (CH >= '1' and CH <= '9') then
               STATE := 3;
            else
               RAISE_APPLICATION_ERROR(- 20601, 'Invalid exponent ' || E.TOKEN || ' found at position ' || CTX.IDX);
            end if;
            E.TOKEN := E.TOKEN || CH;
         elsif (STATE = 2) then
            if (CH >= '1' and CH <= '9') then
               STATE := 3;
            else
               RAISE_APPLICATION_ERROR(- 20601, 'Invalid exponent ' || E.TOKEN || ' found at position ' || CTX.IDX);
            end if;
            E.TOKEN := E.TOKEN || CH;
         elsif (STATE = 3) then
            if (CH >= '1' and CH <= '9') then
               STATE := 3;
            else
               PUSH_BACK(CTX, CH);
               exit;
            end if;
            E.TOKEN := E.TOKEN || CH;
         end if;
      end loop;
   end;
   
   procedure NEXT_FLOAT(CTX in out T_PARSE_CONTEXT, E in out T_JSON_EVENT) is
   STATE number(1) := 0;
   CH char(1);
   begin
      while true loop
         exit when CTX.IDX > CTX.TOTAL_LEN;
         CH := NEXT_C(CTX);
         if (STATE = 0) then
            if (CH = '-') then
               STATE := 1;
            elsif (CH = '0') then
               STATE := 2;
            elsif (CH >= '1' and CH <= '9') then
               STATE := 3;
            else
               RAISE_APPLICATION_ERROR(- 20601, 'Invalid number ' || E.TOKEN || ' found at position ' || CTX.IDX);
            end if;
            E.TOKEN := E.TOKEN || CH;
         elsif (STATE = 1) then
            if (CH = '0') then
               STATE := 2;
            elsif (CH >= '1' and CH <= '9') then
               STATE := 3;
            else
               RAISE_APPLICATION_ERROR(- 20601, 'Invalid number ' || E.TOKEN || ' found at position ' || CTX.IDX);
            end if;
            E.TOKEN := E.TOKEN || CH;
         elsif (STATE = 2) then
            if (CH = '.') then
               STATE := 4;
            else
               PUSH_BACK(CTX, CH);
               exit;
            end if;
            E.TOKEN := E.TOKEN || CH;
         elsif (STATE = 3) then
            if (CH >= '0' and CH <= '9') then
               STATE := 3;
            elsif (CH = '.') then
               STATE := 4;
            else
               PUSH_BACK(CTX, CH);
               exit;
            end if;
            E.TOKEN := E.TOKEN || CH;
         elsif (STATE = 4) then
            if (CH >= '0' and CH <= '9') then
               STATE := 5;
            else
               RAISE_APPLICATION_ERROR(- 20601, 'Invalid number ' || E.TOKEN || ' found at position ' || CTX.IDX);
            end if;
            E.TOKEN := E.TOKEN || CH;
         elsif (STATE = 5) then
            if (CH >= '0' and CH <= '9') then
               STATE := 5;
            else
               PUSH_BACK(CTX, CH);
               exit;
            end if;
            E.TOKEN := E.TOKEN || CH;
         end if;
      end loop;
   end;
   
   procedure NEXT_NUM(CTX in out T_PARSE_CONTEXT, E in out T_JSON_EVENT) is
   CH char(1);
   begin
      NEXT_FLOAT(CTX, E);
      CH := NEXT_C(CTX);
      PUSH_BACK(CTX, CH);
      if (CH in ('E', 'e')) then
         NEXT_EXP(CTX, E);
      end if;
      E.EVENT := EVT_JSON_V_NUM;
   end;
   
   procedure NEXT_TRUE(CTX in out T_PARSE_CONTEXT, E in out T_JSON_EVENT) is
   S varchar(4);
   begin
      S := NEXT_C(CTX, 4);
      if (UPPER(S) = 'TRUE') then
         E.EVENT := EVT_JSON_V_T;
         E.TOKEN := S;
         return;
      end if;
      RAISE_APPLICATION_ERROR(- 20601, 'Invalid boolean ' || S || ' found at position ' || CTX.IDX);
   end;
   
   procedure NEXT_FALSE(CTX in out T_PARSE_CONTEXT, E in out T_JSON_EVENT) is
   S varchar(5);
   begin
      S := NEXT_C(CTX, 5);
      if (UPPER(S) = 'FALSE') then
         E.EVENT := EVT_JSON_V_F;
         E.TOKEN := S;
         return;
      end if;
      RAISE_APPLICATION_ERROR(- 20601, 'Invalid boolean ' || S || ' found at position ' || CTX.IDX);
   end;
   
   procedure NEXT_NULL(CTX in out T_PARSE_CONTEXT, E in out T_JSON_EVENT) is
   S varchar(4);
   begin
      S := NEXT_C(CTX, 4);
      if (UPPER(S) = 'NULL') then
         E.EVENT := EVT_JSON_V_NIL;
         E.TOKEN := S;
         return;
      end if;
      RAISE_APPLICATION_ERROR(- 20601, 'Invalid null ' || S || ' found at position ' || CTX.IDX);
   end;
   
   procedure SET_SC_EVENT(CTX in out T_PARSE_CONTEXT, CH in char, E in out T_JSON_EVENT) is
   begin
      E.TOKEN := CH;
      if (CH = '[') then
         E.EVENT := EVT_JSON_AS;
      elsif (CH = ']') then
         E.EVENT := EVT_JSON_AE;
      elsif (CH = '{') then
         E.EVENT := EVT_JSON_OS;
      elsif (CH = '}') then
         E.EVENT := EVT_JSON_OE;
      elsif (CH = ':') then
         E.EVENT := EVT_JSON_COLON;
      elsif (CH = ',') then
         E.EVENT := EVT_JSON_COMMA;
      else
         RAISE_APPLICATION_ERROR(- 20601, 'Invalid keywords/control character ' || CH || ' found at position ' || CTX.IDX);
      end if;
   end;
   
   procedure NEXT_TK(CTX in out T_PARSE_CONTEXT, E in out T_JSON_EVENT) is
   CH char(1);
   begin
      while true loop
         exit when CTX.IDX > CTX.TOTAL_LEN;
         CH := NEXT_C(CTX);
         if (IS_WS_CHAR(CH)) then
            continue;
         end if;
         if (IS_SP_CHAR(CH)) then
            SET_SC_EVENT(CTX, CH, E);
         elsif (CH = '"') then
            PUSH_BACK(CTX, CH);
            NEXT_STR(CTX, E);
         elsif (CH in ('T', 't')) then
            PUSH_BACK(CTX, CH);
            NEXT_TRUE(CTX, E);
         elsif (CH in ('F', 'f')) then
            PUSH_BACK(CTX, CH);
            NEXT_FALSE(CTX, E);
         elsif (CH in ('N', 'n')) then
            PUSH_BACK(CTX, CH);
            NEXT_NULL(CTX, E);
         else
            PUSH_BACK(CTX, CH);
            NEXT_NUM(CTX, E);
         end if;
         exit;
      end loop;
   end;
   
   procedure NEXT_RAW_E(CTX in out T_PARSE_CONTEXT, E in out T_JSON_EVENT) is
   CNT number := 0;
   STR varchar(32767);
   begin
      NEXT_TK(CTX, E);
      CNT := CTX.E_STACK.COUNT;
      if (E.EVENT in (EVT_JSON_OS, EVT_JSON_AS)) then
         CTX.E_STACK.EXTEND(1);
         CTX.E_STACK(CNT + 1) := E.EVENT;
      elsif (E.EVENT = EVT_JSON_OE) then
         if (CTX.E_STACK(CNT) = EVT_JSON_OS) then
            CTX.E_STACK.TRIM(1);
            if (CNT > 1 and CTX.E_STACK(CNT - 1) = EVT_JSON_ATTR_KEY) then
               CTX.E_STACK.TRIM(1);
            end if;
         elsif (CTX.E_STACK(CNT) in (EVT_JSON_V_STR, EVT_JSON_V_NUM, EVT_JSON_V_F, EVT_JSON_V_T, EVT_JSON_V_NIL) 
                and CTX.E_STACK(CNT - 1) = EVT_JSON_OS) then
            CTX.E_STACK.TRIM(2);
         else
            RAISE_APPLICATION_ERROR(- 20601, 'No object start match found for the object end at position ' || CTX.IDX);
         end if;
      elsif (E.EVENT = EVT_JSON_AE) then
         if (CTX.E_STACK(CNT) = EVT_JSON_AS) then
            CTX.E_STACK.TRIM(1);
            if (CNT > 1 and CTX.E_STACK(CNT - 1) = EVT_JSON_ATTR_KEY) then
               CTX.E_STACK.TRIM(1);
            end if;
         elsif (CTX.E_STACK(CNT) in (EVT_JSON_V_STR, EVT_JSON_V_NUM, EVT_JSON_V_F, EVT_JSON_V_T, EVT_JSON_V_NIL) 
                and CTX.E_STACK(CNT - 1) = EVT_JSON_AS) then
            CTX.E_STACK.TRIM(2);
         else
            RAISE_APPLICATION_ERROR(- 20601, 'No array start match found for the array end at position ' || CTX.IDX);
         end if;
      elsif (E.EVENT in (EVT_JSON_V_STR, EVT_JSON_V_NUM, EVT_JSON_V_F, EVT_JSON_V_T, EVT_JSON_V_NIL)) then
         if (E.EVENT = EVT_JSON_V_STR and CTX.E_STACK(CNT) = EVT_JSON_OS) then
            STR := E.TOKEN;
            NEXT_TK(CTX, E);
            if (E.EVENT <> EVT_JSON_COLON) then
               RAISE_APPLICATION_ERROR(- 20601, 'Invalid object attribute found at position ' || CTX.IDX);
            end if;
            E.TOKEN := STR;
            E.EVENT := EVT_JSON_ATTR_KEY;
            CTX.E_STACK.EXTEND(1);
            CTX.E_STACK(CNT + 1) := E.EVENT;
         elsif (CTX.E_STACK(CNT) = EVT_JSON_ATTR_KEY) then
            CTX.E_STACK.TRIM(1);
         elsif (CTX.E_STACK(CNT) <> EVT_JSON_AS) then
            RAISE_APPLICATION_ERROR(- 20601, 'Invalid json value position found at position ' || CTX.IDX);
         end if;
      elsif (E.EVENT = EVT_JSON_COLON) then
         RAISE_APPLICATION_ERROR(- 20601, 'Invalid colon found at position ' || CTX.IDX);
      elsif (E.EVENT = EVT_JSON_COMMA) then
         if (CTX.E_STACK(CNT) not in (EVT_JSON_OS, EVT_JSON_AS)) then
            RAISE_APPLICATION_ERROR(- 20601, 'Invalid comma found at position ' || CTX.IDX);
         end if;
      else
         RAISE_APPLICATION_ERROR(- 20601, 'Unknown error found at position ' || CTX.IDX);
      end if;
   end;
   
   procedure BEGIN_PARSE(STR in varchar, CTX out T_PARSE_CONTEXT) is
   begin
      CTX.BUF_LMT := MAX_BUF_LMT;
      CTX.BUF_IDX := MAX_BUF_LMT + 1;
      CTX.TOTAL_LEN := LENGTH(STR);
      CTX.STR_DATA := STR;
      CTX.IDX := 1;
      CTX.E_STACK := T_EVENT_STACK();
   end;
   
   procedure NEXT_JSON_EVENT(CTX in out T_PARSE_CONTEXT, E out nocopy T_JSON_EVENT) is
   begin
      while true loop
         if (CTX.IDX > CTX.TOTAL_LEN) then
            E.EVENT := EVT_JSON_EOF;
            exit;
         end if;
         NEXT_RAW_E(CTX, E);
         if (E.EVENT not in (EVT_JSON_COMMA, EVT_JSON_COLON)) then
            return;
         end if;
         E.TOKEN := '';
      end loop;
   end;
end PL_JSON_STREAM;
/