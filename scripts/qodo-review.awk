# AGENTS.md rule 9: parses one Qodo review body, a "Code Review by Qodo" comment, into the records
# that scripts/generate-delivery.sh (one call per version of the comment) and
# scripts/qodo-status.sh and scripts/qodo-gate.sh (the latest review) read. This file is the only
# parser of Qodo's layout, so a new layout is fixed here and nowhere else.
#
# Usage: awk -v vnum=N -f scripts/qodo-review.awk BODY
#   vnum  the review's number, copied into each record (1 for a single review).
#
# Output: tab-separated records, one per line.
#   V vnum sha                 the commit the review names (its marker <!-- .../commit/<sha> -->);
#                              empty when it names none
#   C vnum                     the review is clear (see below)
#   F vnum sev key kind title  one per finding: its severity, its key (the id in its /findings/
#                              link, else "title:" and the title), its kind and its title
#
# A review is clear only when it has no "<strong>View " header, every group opener (a badge line
# for High, Medium or Low) is followed by "Nice, no open findings for this group" before the next
# opener or the review's end, and at least one clear phrase was seen. "Great, no issues found!"
# (PR #35's layout) counts only when the review has no opener. Anything else is not clear, so a
# layout this parse misses cannot read as zero.
      function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
      {
        if (sha == "" && substr($0, 1, 5) == "<!-- " && (i = index($0, "/commit/")) > 0) {
          s = substr($0, i + 8, 40)
          if (length(s) == 40 && s ~ /^[0-9a-f]+$/) sha = s
        }
        if ((i = index($0, "<strong>View ")) > 0) {
          s = substr($0, i + 13)
          sub(/[ <].*$/, "", s)
          sev = s
          view = 1
          next
        }
        if ($0 ~ /<summary>[ \t]*[0-9]+\.[ \t]/) {
          n++; last = n
          s = $0
          sub(/^.*<summary>[ \t]*[0-9]+\.[ \t]/, "", s)
          sub(/<\/summary>.*$/, "", s)
          k = index(s, "<code>")
          t = (k > 0) ? substr(s, 1, k - 1) : s
          codes = (k > 0) ? substr(s, k) : ""
          kind = ""
          while ((k = index(codes, "<code>")) > 0) {
            codes = substr(codes, k + 6)
            e = index(codes, "</code>")
            c = (e > 0) ? substr(codes, 1, e - 1) : codes
            if (kind == "" && index(c, "New") == 0) kind = c
            codes = (e > 0) ? substr(codes, e + 7) : ""
          }
          gsub(/\t/, " ", t); gsub(/\t/, " ", kind)
          ft[n] = trim(t); fk[n] = trim(kind); fu[n] = ""; fsev[n] = sev
          next
        }
        if (last > 0 && fu[last] == "" && (i = index($0, "/findings/")) > 0) fu[last] = substr($0, i + 10, 36)
        if ($0 ~ /badge\/(High|Medium|Low)-/) {
          if (open) bad = 1
          open = 1
          groups++
        }
        if (index($0, "Nice, no open findings for this group") > 0) { nice++; open = 0 }
        if (index($0, "Great, no issues found!") > 0) great++
      }
      END {
        if (open) bad = 1
        if (!view && !bad && (nice > 0 || (great > 0 && groups == 0))) clr = 1
        print "V\t" vnum "\t" sha
        if (clr) print "C\t" vnum
        for (j = 1; j <= n; j++) {
          key = fu[j]
          if (key == "") key = "title:" ft[j]
          print "F\t" vnum "\t" fsev[j] "\t" key "\t" fk[j] "\t" ft[j]
        }
      }
