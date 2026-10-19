# EPlusTV 4.16.6; source: https://github.com/tonywagner/EPlusTV
# The upstream application and these modifications retain the MIT license.
FROM tonywagner/eplustv@sha256:ce668bcfe953fe7c3631d44e7401ea798bc20015d9c84ab5ec829bfae921bb57
COPY foxone-hardening.patch /tmp/velvet-tve.patch
RUN apk add --no-cache patch \
 && cd /app && patch -p1 < /tmp/velvet-tve.patch \
 && rm /tmp/velvet-tve.patch && apk del patch
