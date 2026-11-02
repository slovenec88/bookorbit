import { ForbiddenException, ValidationPipe } from '@nestjs/common';
import type { ExecutionContext } from '@nestjs/common';
import { FastifyAdapter, NestFastifyApplication } from '@nestjs/platform-fastify';
import { Test } from '@nestjs/testing';
import { Permission } from '@bookorbit/types';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { PermissionService } from '../../common/services/permission.service';
import type { RequestUser } from '../../common/types/request-user';
import { BookRequestService } from '../book-request/book-request.service';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderRequestController } from './koreader-request.controller';
import { KoreaderRequestGuard } from './koreader-request.guard';

describe('KOReader request routes', () => {
  let app: NestFastifyApplication;
  let user: RequestUser;
  const service = {
    getRequesterLibraries: vi.fn().mockResolvedValue([{ id: 5, name: 'Books' }]),
    canManageAll: vi.fn().mockReturnValue(false),
    canSelfFulfil: vi.fn().mockReturnValue(false),
    submit: vi.fn().mockResolvedValue({ request: { id: 9, status: 'pending' }, subscribed: false }),
    submitPair: vi.fn().mockResolvedValue({
      ebook: { request: { id: 9, mediaKind: 'ebook', status: 'pending' }, subscribed: false },
      audiobook: { request: { id: 10, mediaKind: 'audiobook', status: 'approved' }, subscribed: true },
    }),
    listMine: vi.fn().mockResolvedValue({ items: [], total: 0 }),
    getOne: vi.fn().mockResolvedValue({ id: 9, status: 'available', matchedBookId: 7 }),
    cancel: vi.fn().mockResolvedValue({ id: 9, status: 'cancelled' }),
    unsubscribe: vi.fn().mockResolvedValue(undefined),
  };
  const base = '/koreader/plugin/requests';

  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [KoreaderRequestController],
      providers: [KoreaderRequestGuard, PermissionService, { provide: BookRequestService, useValue: service }],
    })
      .overrideGuard(KoreaderAuthGuard)
      .useValue({
        canActivate(context: ExecutionContext) {
          context.switchToHttp().getRequest<{ user: RequestUser }>().user = user;
          return true;
        },
      })
      .compile();
    app = module.createNestApplication<NestFastifyApplication>(new FastifyAdapter());
    app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
    await app.init();
    await app.getHttpAdapter().getInstance().ready();
  });
  afterAll(async () => app.close());
  beforeEach(() => {
    vi.clearAllMocks();
    user = { id: 42, permissions: [Permission.KoreaderSync, Permission.BookRequestAccess], isSuperuser: false } as RequestUser;
  });

  it('requires KOReader authentication before its explicit request permission guard', () => {
    expect(Reflect.getMetadata('__guards__', KoreaderRequestController)).toEqual([KoreaderAuthGuard, KoreaderRequestGuard]);
  });

  it.each([
    ['GET', '/access'],
    ['GET', ''],
    ['GET', '/9'],
    ['POST', ''],
    ['POST', '/pairs'],
    ['POST', '/9/cancel'],
    ['DELETE', '/9/subscription'],
  ] as const)('refuses %s %s without request permission', async (method, suffix) => {
    user.permissions = [Permission.KoreaderSync];
    const response = await app.inject({ method, url: base + suffix });
    expect(response.statusCode).toBe(403);
    expect(Object.values(service).every((mock) => mock.mock.calls.length === 0)).toBe(true);
  });

  it('returns the current user and their destination choices', async () => {
    const response = await app.inject({ method: 'GET', url: base + '/access' });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ userId: 42, libraries: [{ id: 5, name: 'Books' }], canManageRequests: false, canSelfFulfil: false });
    expect(service.getRequesterLibraries).toHaveBeenCalledWith(user);
    expect(response.headers['cache-control']).toBe('no-store');
  });

  it.each(['ebook', 'audiobook'])('submits a validated %s request as the authenticated user', async (mediaKind) => {
    const payload = { title: 'Dune', authors: ['Frank Herbert'], mediaKind, language: 'en', note: 'Please', targetLibraryId: 5 };
    const response = await app.inject({ method: 'POST', url: base, payload });
    expect(response.statusCode).toBe(201);
    expect(response.json()).toEqual({ request: { id: 9, status: 'pending' }, subscribed: false });
    expect(service.submit).toHaveBeenCalledWith(payload, user);
  });

  it('preserves a deduplicated subscription result', async () => {
    service.submit.mockResolvedValueOnce({ request: { id: 9, status: 'pending' }, subscribed: true });
    const response = await app.inject({ method: 'POST', url: base, payload: { title: 'Dune', mediaKind: 'ebook' } });
    expect(response.json().subscribed).toBe(true);
  });

  it.each([
    { title: 'Dune', authors: ['Frank Herbert'], language: 'en', note: 'Both formats please' },
    { title: 'Dune', ebook: { targetLibraryId: 5 }, audiobook: { targetLibraryId: 6 } },
  ])('submits an ebook and audiobook pair using defaults or explicit per-medium destinations', async (payload) => {
    const response = await app.inject({ method: 'POST', url: base + '/pairs', payload });
    expect(response.statusCode).toBe(201);
    expect(service.submitPair).toHaveBeenCalledWith(payload, user);
    expect(service.submit).not.toHaveBeenCalled();
    expect(response.json()).toEqual({
      ebook: { request: { id: 9, mediaKind: 'ebook', status: 'pending' }, subscribed: false },
      audiobook: { request: { id: 10, mediaKind: 'audiobook', status: 'approved' }, subscribed: true },
    });
  });

  it.each([
    { title: 'Dune', mediaKind: 'both' },
    { title: 'Dune', targetLibraryId: 5 },
    { title: 'Dune', ebook: [], audiobook: [] },
    { title: 'Dune', ebook: { targetLibraryId: 0 } },
    { title: 'Dune', audiobook: { unknown: true } },
    { title: 'x'.repeat(501) },
  ])('refuses malformed pair payloads before the service', async (payload) => {
    const response = await app.inject({ method: 'POST', url: base + '/pairs', payload });
    expect(response.statusCode).toBe(400);
    expect(service.submitPair).not.toHaveBeenCalled();
  });

  it('tracks and cancels each half of a pair by its own request id', async () => {
    service.getOne.mockResolvedValueOnce({ id: 9, mediaKind: 'ebook', status: 'pending', matchedBookId: 0 });
    service.getOne.mockResolvedValueOnce({ id: 10, mediaKind: 'audiobook', status: 'available', matchedBookId: 7 });
    const ebook = await app.inject({ method: 'GET', url: base + '/9' });
    const audiobook = await app.inject({ method: 'GET', url: base + '/10' });
    expect(ebook.json()).toMatchObject({ id: 9, status: 'pending' });
    expect(audiobook.json()).toMatchObject({ id: 10, status: 'available' });
    await app.inject({ method: 'POST', url: base + '/9/cancel' });
    expect(service.cancel).toHaveBeenCalledExactlyOnceWith(9, user);
    expect(service.getOne).toHaveBeenNthCalledWith(1, 9, user);
    expect(service.getOne).toHaveBeenNthCalledWith(2, 10, user);
  });

  it.each([
    { title: 'Dune', mediaKind: 'video' },
    { title: 'x'.repeat(501), mediaKind: 'ebook' },
    { title: 'Dune', mediaKind: 'ebook', unknown: true },
  ])('refuses an invalid payload before submission', async (payload) => {
    expect((await app.inject({ method: 'POST', url: base, payload })).statusCode).toBe(400);
    expect(service.submit).not.toHaveBeenCalled();
  });

  it('bounds pagination and never accepts a different requester on the personal list', async () => {
    const response = await app.inject({ method: 'GET', url: base + '?page=2&limit=3&mediaKind=audiobook&sortBy=createdAt&sortDir=desc' });
    expect(response.statusCode).toBe(200);
    expect(service.listMine).toHaveBeenCalledWith(expect.objectContaining({ page: 2, limit: 3, mediaKind: 'audiobook' }), user);
    for (const query of ['limit=101', 'page=0', 'requesterUserId=99']) {
      expect((await app.inject({ method: 'GET', url: base + '?' + query })).statusCode).toBe(400);
    }
  });

  it('passes detail, cancel and unsubscribe through ownership-aware services', async () => {
    expect((await app.inject({ method: 'GET', url: base + '/9' })).json().matchedBookId).toBe(7);
    expect((await app.inject({ method: 'POST', url: base + '/9/cancel' })).json().status).toBe('cancelled');
    expect((await app.inject({ method: 'DELETE', url: base + '/9/subscription' })).statusCode).toBe(204);
    expect(service.getOne).toHaveBeenCalledWith(9, user);
    expect(service.cancel).toHaveBeenCalledWith(9, user);
    expect(service.unsubscribe).toHaveBeenCalledWith(9, user);
    service.getOne.mockRejectedValueOnce(new ForbiddenException());
    expect((await app.inject({ method: 'GET', url: base + '/99' })).statusCode).toBe(403);
  });

  it('honours superuser permission semantics', async () => {
    user.isSuperuser = true;
    user.permissions = [];
    expect((await app.inject({ method: 'GET', url: base })).statusCode).toBe(200);
  });
});
