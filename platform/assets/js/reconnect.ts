// Phoenix's own waits between reconnect attempts, each spread from half to
// one and a half times its length. A deploy drops every open page at once;
// without the spread they all come back in the same instant and each reads
// its page again, more than the site's few database connections can answer.
export const reconnectWaits = [10, 50, 100, 150, 200, 250, 500, 1000, 2000]

export const spreadReconnect = (tries: number) => {
  const wait = reconnectWaits[tries - 1] ?? 5000
  return Math.round(wait / 2 + Math.random() * wait)
}
