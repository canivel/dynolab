"""Parse explicit model-emitted thinking delimiters; never infer private reasoning."""


def split_thinking(text, enabled, prompt_has_open_think=False):
    if not isinstance(text, str):
        raise ValueError('Generated text must be a string')
    if not enabled:
        if '<think>' in text or '</think>' in text:
            return dict(status='unexpected_markers', thinking=None, answer=None)
        return dict(status='disabled', thinking=None, answer=text, answer_start=0)
    start = 0
    if not prompt_has_open_think:
        leading = len(text)-len(text.lstrip())
        if not text[leading:].startswith('<think>'):
            return dict(status='missing_open_marker', thinking=None, answer=None)
        start = leading+len('<think>')
    end = text.find('</think>', start)
    if end < 0:
        return dict(status='incomplete', thinking=text[start:], answer=None, thinking_start=start)
    if '<think>' in text[start:] or '</think>' in text[end+len('</think>'):]:
        return dict(status='ambiguous_markers', thinking=None, answer=None)
    return dict(status='complete', thinking=text[start:end], answer=text[end+len('</think>'):],
                thinking_start=start, thinking_end=end, answer_start=end+len('</think>'))
