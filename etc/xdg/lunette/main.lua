-- The default lunette session.
--
-- It draws a single line of text, which is enough to show that the host booted
-- LÖVR, found this directory, and is presenting frames.

function lovr.draw(pass)
  pass:text('lunette', 0, 1.7, -3, 0.2)
end
